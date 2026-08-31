#!/usr/bin/env bash

# Build and install the private BookPlayer Sync app without placing Supabase
# credentials in the repository. Credentials are read from macOS Keychain.

set -euo pipefail

target="${1:-both}"
case "$target" in
  phone|mac|both) ;;
  *)
    echo "Usage: scripts/device-install.sh [phone|mac|both]" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
project="$repo_root/BookPlayer.xcodeproj"
scheme="BookPlayer"
bundle_id="com.tarioyou.bookplayersync"
team_id="K8836C2S7M"
phone_id="00008120-0014441A1E87A01E"
mac_id="00006030-001C78522279001C"
lease_script="/Users/tarioyou/moonshot-mobile/scripts/with-build-lease.sh"

anon_key="$(security find-generic-password \
  -s codex.bookplayer.supabase.anon-key \
  -a tarioyou \
  -w)"
library_secret="$(security find-generic-password \
  -s codex.bookplayer.supabase.library-secret \
  -a tarioyou \
  -w)"

if [[ -z "$anon_key" || ${#library_secret} -lt 32 ]]; then
  echo "BookPlayer Sync credentials are missing from macOS Keychain" >&2
  exit 1
fi

build_app() {
  local destination_id="$1"
  local derived_data="$2"

  MOONSHOT_BUILD_WHY=dev-merge-phone "$lease_script" \
    /usr/bin/xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "id=$destination_id" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_ENTITLEMENTS=BookPlayer/BookPlayer-Personal.entitlements \
    PROVISIONING_PROFILE_SPECIFIER= \
    BP_ENTITLEMENTS=BookPlayer-Personal \
    BP_BUNDLE_IDENTIFIER="$bundle_id" \
    "BP_DISPLAY_NAME=BookPlayer Sync" \
    'BP_PERSONAL_SYNC_URL=https:/$()/xtcxqmjnzjzgvnoejdup.supabase.co' \
    BP_PERSONAL_SYNC_ANON_KEY="$anon_key" \
    BP_PERSONAL_SYNC_LIBRARY_SECRET="$library_secret" \
    build
}

find_app() {
  local derived_data="$1"
  local app_path
  app_path="$(find "$derived_data/Build/Products" -type d -name BookPlayer.app -prune | head -n 1)"
  if [[ -z "$app_path" ]]; then
    echo "Built BookPlayer.app was not found under $derived_data" >&2
    exit 1
  fi
  printf '%s\n' "$app_path"
}

install_phone() {
  local derived_data="$repo_root/DerivedData/PersonalSyncPhone"
  build_app "$phone_id" "$derived_data"
  local app_path
  app_path="$(find_app "$derived_data")"

  xcrun devicectl device install app --device "$phone_id" "$app_path"
  xcrun devicectl device process launch \
    --device "$phone_id" \
    --terminate-existing \
    "$bundle_id"
}

install_mac() {
  local derived_data="$repo_root/DerivedData/PersonalSyncMac"
  local destination="/Applications/BookPlayer Sync.app"
  build_app "$mac_id" "$derived_data"
  local app_path
  app_path="$(find_app "$derived_data")"

  ditto "$app_path" "$destination"
  codesign --verify --deep --strict "$destination"
  open -g "$destination"
}

case "$target" in
  phone) install_phone ;;
  mac) install_mac ;;
  both)
    install_phone
    install_mac
    ;;
esac
