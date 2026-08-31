//
//  PersonalSyncService.swift
//  BookPlayer
//

import BookPlayerKit
import Combine
import Foundation
import UIKit

@MainActor
final class PersonalSyncService: BPLogger {
  private let configuration: PersonalSyncConfiguration?
  private let pendingStore: PersonalSyncPendingStore
  private let defaults: UserDefaults

  private var client: (any PersonalSyncClientProtocol)?
  private weak var libraryService: LibraryService?
  private weak var playerManager: PlayerManager?
  private var pending: [String: PersonalSyncRecord]
  private var ignoredRemoteEvents: [String: Date] = [:]
  private var cancellables = Set<AnyCancellable>()
  private var syncTask: Task<Void, Never>?
  private(set) var isEnabled = false

  private lazy var deviceID: UUID = {
    let key = "personalSync.deviceID"
    if let value = defaults.string(forKey: key), let id = UUID(uuidString: value) {
      return id
    }
    let id = UUID()
    defaults.set(id.uuidString, forKey: key)
    return id
  }()

  init(
    configuration: PersonalSyncConfiguration? = PersonalSyncConfiguration(),
    client: (any PersonalSyncClientProtocol)? = nil,
    pendingStore: PersonalSyncPendingStore = PersonalSyncPendingStore(),
    defaults: UserDefaults = .standard
  ) {
    self.configuration = configuration
    self.client = client
    self.pendingStore = pendingStore
    self.defaults = defaults
    self.pending = pendingStore.load()
  }

  func setup(libraryService: LibraryService, playerManager: PlayerManager) {
    guard let configuration else {
      Self.logger.info("Personal sync is not configured")
      return
    }

    self.libraryService = libraryService
    self.playerManager = playerManager
    if client == nil {
      client = PersonalSyncClient(configuration: configuration)
    }
    isEnabled = true

    libraryService.progressUpdatePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] payload in
        self?.handleProgressUpdate(payload)
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .bookPaused)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.captureCurrentItemAndSync()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.scheduleSync()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.captureCurrentItemAndSync()
      }
      .store(in: &cancellables)

    Timer.publish(every: 60, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in
        self?.scheduleSync()
      }
      .store(in: &cancellables)

    scheduleSync()
  }

  private func handleProgressUpdate(_ payload: [String: Any]) {
    guard
      let relativePath = payload[#keyPath(LibraryItem.relativePath)] as? String,
      let item = libraryService?.getSimpleItem(with: relativePath)
    else {
      return
    }

    let eventAt: Date
    if let timestamp = payload[#keyPath(LibraryItem.lastPlayDate)] as? TimeInterval {
      eventAt = Date(timeIntervalSince1970: timestamp)
    } else {
      eventAt = item.lastPlayDate ?? Date()
    }

    let record = PersonalSyncRecord(item: item, eventAt: eventAt, sourceDeviceId: deviceID)
    if let ignoredEventAt = ignoredRemoteEvents[record.itemKey],
      abs(ignoredEventAt.timeIntervalSince(record.eventAt)) < 0.001
    {
      ignoredRemoteEvents.removeValue(forKey: record.itemKey)
      return
    }

    enqueue(record)
    scheduleSync()
  }

  private func captureCurrentItemAndSync() {
    guard
      let relativePath = playerManager?.currentItem?.relativePath,
      let item = libraryService?.getSimpleItem(with: relativePath)
    else {
      scheduleSync()
      return
    }

    let record = PersonalSyncRecord(
      item: item,
      eventAt: item.lastPlayDate ?? Date(),
      sourceDeviceId: deviceID
    )
    enqueue(record)
    scheduleSync()
  }

  private func enqueue(_ record: PersonalSyncRecord) {
    if let existing = pending[record.itemKey], existing.eventAt > record.eventAt {
      return
    }
    pending[record.itemKey] = record
    pendingStore.save(pending)
  }

  private func scheduleSync() {
    guard isEnabled, syncTask == nil else { return }

    syncTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSync()
      self.syncTask = nil
    }
  }

  private func performSync() async {
    guard let client else { return }

    let queued = pending.values.sorted { $0.eventAt < $1.eventAt }
    for record in queued {
      do {
        let serverRecord = try await client.push(record)
        if pending[record.itemKey]?.eventAt == record.eventAt {
          pending.removeValue(forKey: record.itemKey)
          pendingStore.save(pending)
        }
        applyIfNewer(serverRecord)
      } catch {
        Self.logger.error("Personal sync upload failed: \(error.localizedDescription)")
        return
      }
    }

    do {
      let remoteRecords = try await client.pullAll()
      remoteRecords.forEach(applyIfNewer)
    } catch {
      Self.logger.error("Personal sync download failed: \(error.localizedDescription)")
    }
  }

  private func applyIfNewer(_ record: PersonalSyncRecord) {
    guard
      let libraryService,
      let localItem = localItem(for: record, libraryService: libraryService),
      PersonalSyncReconciler.shouldApply(
        remote: record,
        local: localItem,
        localDeviceID: deviceID
      )
    else {
      return
    }

    if playerManager?.isPlaying == true,
      playerManager?.currentItem?.relativePath == localItem.relativePath
    {
      return
    }

    ignoredRemoteEvents[record.itemKey] = record.eventAt
    if localItem.isFinished != record.isFinished {
      libraryService.markAsFinished(
        flag: record.isFinished,
        relativePath: localItem.relativePath
      )
    }
    libraryService.updatePlaybackTime(
      relativePath: localItem.relativePath,
      time: TimeInterval(record.positionMs) / 1_000,
      date: record.eventAt,
      scheduleSave: false
    )

    if playerManager?.currentItem?.relativePath == localItem.relativePath {
      playerManager?.applyExternalProgress(
        relativePath: localItem.relativePath,
        time: TimeInterval(record.positionMs) / 1_000
      )
    }
  }

  private func localItem(
    for record: PersonalSyncRecord,
    libraryService: LibraryService
  ) -> SimpleLibraryItem? {
    for relativePath in libraryService.fetchIdentifiers() {
      guard let item = libraryService.getSimpleItem(with: relativePath) else { continue }
      if PersonalSyncRecord.itemKey(for: item) == record.itemKey {
        return item
      }
    }
    return nil
  }
}
