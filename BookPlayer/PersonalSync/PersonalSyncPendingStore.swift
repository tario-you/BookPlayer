//
//  PersonalSyncPendingStore.swift
//  BookPlayer
//

import Foundation

struct PersonalSyncPendingStore {
  private let defaults: UserDefaults
  private let key: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    key: String = "personalSync.pendingProgress"
  ) {
    self.defaults = defaults
    self.key = key
  }

  func load() -> [String: PersonalSyncRecord] {
    guard let data = defaults.data(forKey: key) else { return [:] }
    return (try? decoder.decode([String: PersonalSyncRecord].self, from: data)) ?? [:]
  }

  func save(_ records: [String: PersonalSyncRecord]) {
    guard !records.isEmpty else {
      defaults.removeObject(forKey: key)
      return
    }
    if let data = try? encoder.encode(records) {
      defaults.set(data, forKey: key)
    }
  }
}
