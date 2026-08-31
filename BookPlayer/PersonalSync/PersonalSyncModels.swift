//
//  PersonalSyncModels.swift
//  BookPlayer
//

import BookPlayerKit
import CryptoKit
import Foundation

struct PersonalSyncConfiguration: Sendable {
  let projectURL: URL
  let apiKey: String
  let librarySecret: String

  init(projectURL: URL, apiKey: String, librarySecret: String) {
    self.projectURL = projectURL
    self.apiKey = apiKey
    self.librarySecret = librarySecret
  }

  init?(bundle: Bundle = .main) {
    guard
      let urlString = bundle.object(forInfoDictionaryKey: "BP_PERSONAL_SYNC_URL") as? String,
      let projectURL = URL(string: urlString),
      projectURL.scheme == "https",
      let apiKey = bundle.object(forInfoDictionaryKey: "BP_PERSONAL_SYNC_ANON_KEY") as? String,
      !apiKey.isEmpty,
      !apiKey.contains("$("),
      let librarySecret = bundle.object(forInfoDictionaryKey: "BP_PERSONAL_SYNC_LIBRARY_SECRET") as? String,
      librarySecret.count >= 32,
      !librarySecret.contains("$(")
    else {
      return nil
    }

    self.init(
      projectURL: projectURL,
      apiKey: apiKey,
      librarySecret: librarySecret
    )
  }
}

struct PersonalSyncRecord: Codable, Equatable, Sendable {
  let itemKey: String
  let displayTitle: String
  let durationMs: Int64
  let positionMs: Int64
  let isFinished: Bool
  let eventAt: Date
  let sourceDeviceId: UUID
  let serverUpdatedAt: Date?

  init(
    itemKey: String,
    displayTitle: String,
    durationMs: Int64,
    positionMs: Int64,
    isFinished: Bool,
    eventAt: Date,
    sourceDeviceId: UUID,
    serverUpdatedAt: Date? = nil
  ) {
    self.itemKey = itemKey
    self.displayTitle = displayTitle
    self.durationMs = max(durationMs, 0)
    if durationMs > 0 {
      self.positionMs = min(max(positionMs, 0), durationMs)
    } else {
      self.positionMs = max(positionMs, 0)
    }
    self.isFinished = isFinished
    self.eventAt = eventAt
    self.sourceDeviceId = sourceDeviceId
    self.serverUpdatedAt = serverUpdatedAt
  }

  init(item: SimpleLibraryItem, eventAt: Date, sourceDeviceId: UUID) {
    self.init(
      itemKey: Self.itemKey(for: item),
      displayTitle: item.title,
      durationMs: Self.milliseconds(item.duration),
      positionMs: Self.milliseconds(item.currentTime),
      isFinished: item.isFinished,
      eventAt: eventAt,
      sourceDeviceId: sourceDeviceId
    )
  }

  static func itemKey(for item: SimpleLibraryItem) -> String {
    itemKey(originalFileName: item.originalFileName, duration: item.duration)
  }

  static func itemKey(originalFileName: String, duration: TimeInterval) -> String {
    let normalizedName = originalFileName
      .precomposedStringWithCanonicalMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let input = "\(normalizedName)|\(milliseconds(duration))"
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func milliseconds(_ value: TimeInterval) -> Int64 {
    guard value.isFinite else { return 0 }
    return Int64((value * 1_000).rounded())
  }
}

enum PersonalSyncReconciler {
  static func shouldApply(
    remote: PersonalSyncRecord,
    local: SimpleLibraryItem,
    localDeviceID: UUID
  ) -> Bool {
    guard remote.sourceDeviceId != localDeviceID else { return false }
    guard remote.itemKey == PersonalSyncRecord.itemKey(for: local) else { return false }

    let localEventAt = local.lastPlayDate ?? .distantPast
    if remote.eventAt != localEventAt {
      return remote.eventAt > localEventAt
    }

    return remote.sourceDeviceId.uuidString > localDeviceID.uuidString
  }
}
