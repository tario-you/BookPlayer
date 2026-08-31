//
//  UserDefaults+BookPlayer.swift
//  BookPlayer
//
//  Created by Gianni Carlo on 3/11/23.
//  Copyright © 2023 BookPlayer LLC. All rights reserved.
//

import Foundation

extension UserDefaults {
  public static var sharedDefaults = UserDefaults(suiteName: Constants.ApplicationGroupIdentifier) ?? .standard

  @objc public dynamic var userSettingsAppIcon: String? {
    return string(forKey: Constants.UserDefaults.appIcon)
  }

  @objc public dynamic var userSettingsCrashReportsDisabled: Bool {
    return bool(forKey: Constants.UserDefaults.crashReportsDisabled)
  }

  @objc public dynamic var userSettingsAllowCellularData: Bool {
    return bool(forKey: Constants.UserDefaults.allowCellularData)
  }

  @objc public dynamic var userSettingsBoostVolume: Bool {
    return bool(forKey: Constants.UserDefaults.boostVolumeEnabled)
  }

  @objc public dynamic var userSettingsUpdateProgress: Bool {
    return bool(forKey: Constants.UserDefaults.updateProgress)
  }

  @objc public dynamic var userSettingsRewindInterval: TimeInterval {
    return double(forKey: Constants.UserDefaults.rewindInterval)
  }

  @objc public dynamic var userSettingsForwardInterval: TimeInterval {
    return double(forKey: Constants.UserDefaults.forwardInterval)
  }

  @objc public dynamic var userSettingsOrientationLock: Bool {
    return bool(forKey: Constants.UserDefaults.orientationLock)
  }
}
