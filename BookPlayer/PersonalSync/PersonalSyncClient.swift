//
//  PersonalSyncClient.swift
//  BookPlayer
//

import Foundation

protocol PersonalSyncClientProtocol: Sendable {
  func push(_ record: PersonalSyncRecord) async throws -> PersonalSyncRecord
  func pullAll() async throws -> [PersonalSyncRecord]
}

enum PersonalSyncClientError: Error, Equatable {
  case invalidResponse
  case httpStatus(Int)
  case emptyPushResponse
}

actor PersonalSyncClient: PersonalSyncClientProtocol {
  private struct PushPayload: Encodable {
    let librarySecret: String
    let record: PersonalSyncRecord

    enum CodingKeys: String, CodingKey {
      case librarySecret = "p_library_secret"
      case itemKey = "p_item_key"
      case displayTitle = "p_display_title"
      case durationMs = "p_duration_ms"
      case positionMs = "p_position_ms"
      case isFinished = "p_is_finished"
      case eventAt = "p_event_at"
      case sourceDeviceId = "p_source_device_id"
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(librarySecret, forKey: .librarySecret)
      try container.encode(record.itemKey, forKey: .itemKey)
      try container.encode(record.displayTitle, forKey: .displayTitle)
      try container.encode(record.durationMs, forKey: .durationMs)
      try container.encode(record.positionMs, forKey: .positionMs)
      try container.encode(record.isFinished, forKey: .isFinished)
      try container.encode(record.eventAt, forKey: .eventAt)
      try container.encode(record.sourceDeviceId, forKey: .sourceDeviceId)
    }
  }

  private struct PullPayload: Encodable {
    let librarySecret: String

    enum CodingKeys: String, CodingKey {
      case librarySecret = "p_library_secret"
    }
  }

  private let configuration: PersonalSyncConfiguration
  private let session: URLSession
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(
    configuration: PersonalSyncConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var container = encoder.singleValueContainer()
      try container.encode(formatter.string(from: date))
    }
    self.encoder = encoder

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      let standardFormatter = ISO8601DateFormatter()
      if let date = fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid ISO-8601 timestamp"
      )
    }
    self.decoder = decoder
  }

  func push(_ record: PersonalSyncRecord) async throws -> PersonalSyncRecord {
    let body = try encoder.encode(
      PushPayload(librarySecret: configuration.librarySecret, record: record)
    )
    let data = try await perform(function: "bookplayer_push_progress", body: body)
    guard let record = try decoder.decode([PersonalSyncRecord].self, from: data).first else {
      throw PersonalSyncClientError.emptyPushResponse
    }
    return record
  }

  func pullAll() async throws -> [PersonalSyncRecord] {
    let body = try encoder.encode(
      PullPayload(librarySecret: configuration.librarySecret)
    )
    let data = try await perform(function: "bookplayer_pull_progress", body: body)
    return try decoder.decode([PersonalSyncRecord].self, from: data)
  }

  private func perform(function: String, body: Data) async throws -> Data {
    let url = configuration.projectURL
      .appendingPathComponent("rest/v1/rpc")
      .appendingPathComponent(function)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 20
    request.setValue(configuration.apiKey, forHTTPHeaderField: "apikey")
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw PersonalSyncClientError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw PersonalSyncClientError.httpStatus(response.statusCode)
    }
    return data
  }

}
