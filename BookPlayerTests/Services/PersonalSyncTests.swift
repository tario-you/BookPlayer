//
//  PersonalSyncTests.swift
//  BookPlayerTests
//

import Foundation
import XCTest

@testable import BookPlayer
@testable import BookPlayerKit

final class PersonalSyncTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "PersonalSyncTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    PersonalSyncURLProtocol.requestHandler = nil
    super.tearDown()
  }

  func testItemKeyIsStableAcrossCaseAndUnicodeNormalization() {
    let composed = PersonalSyncRecord.itemKey(
      originalFileName: "  Café.M4B ",
      duration: 3_600.25
    )
    let decomposed = PersonalSyncRecord.itemKey(
      originalFileName: "cafe\u{301}.m4b",
      duration: 3_600.25
    )

    XCTAssertEqual(composed, decomposed)
  }

  func testReconcilerAcceptsNewerRemoteProgress() {
    let localDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let remoteDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let local = makeItem(lastPlayDate: Date(timeIntervalSince1970: 100))
    let remote = PersonalSyncRecord(
      itemKey: PersonalSyncRecord.itemKey(for: local),
      displayTitle: local.title,
      durationMs: 60_000,
      positionMs: 42_000,
      isFinished: false,
      eventAt: Date(timeIntervalSince1970: 101),
      sourceDeviceId: remoteDeviceID
    )

    XCTAssertTrue(
      PersonalSyncReconciler.shouldApply(
        remote: remote,
        local: local,
        localDeviceID: localDeviceID
      )
    )
  }

  func testReconcilerRejectsStaleAndSameDeviceProgress() {
    let localDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let local = makeItem(lastPlayDate: Date(timeIntervalSince1970: 100))
    let stale = PersonalSyncRecord(
      itemKey: PersonalSyncRecord.itemKey(for: local),
      displayTitle: local.title,
      durationMs: 60_000,
      positionMs: 5_000,
      isFinished: false,
      eventAt: Date(timeIntervalSince1970: 99),
      sourceDeviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let sameDevice = PersonalSyncRecord(
      itemKey: stale.itemKey,
      displayTitle: stale.displayTitle,
      durationMs: stale.durationMs,
      positionMs: 42_000,
      isFinished: false,
      eventAt: Date(timeIntervalSince1970: 101),
      sourceDeviceId: localDeviceID
    )

    XCTAssertFalse(
      PersonalSyncReconciler.shouldApply(
        remote: stale,
        local: local,
        localDeviceID: localDeviceID
      )
    )
    XCTAssertFalse(
      PersonalSyncReconciler.shouldApply(
        remote: sameDevice,
        local: local,
        localDeviceID: localDeviceID
      )
    )
  }

  func testPendingStoreSurvivesRelaunch() {
    let record = makeRecord()
    PersonalSyncPendingStore(defaults: defaults).save([record.itemKey: record])

    let reloaded = PersonalSyncPendingStore(defaults: defaults).load()

    XCTAssertEqual(reloaded, [record.itemKey: record])
  }

  func testClientPushUsesPrivateRPCAndDecodesWinner() async throws {
    let expected = makeRecord()
    PersonalSyncURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url?.path, "/rest/v1/rpc/bookplayer_push_progress")
      XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "public-key")
      XCTAssertEqual(request.httpMethod, "POST")

      let body = try Self.bodyData(from: request)
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      XCTAssertEqual(json["p_library_secret"] as? String, String(repeating: "s", count: 32))
      XCTAssertEqual(json["p_position_ms"] as? Int, Int(expected.positionMs))

      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )!,
        Self.rpcData(for: [expected])
      )
    }
    let client = PersonalSyncClient(
      configuration: makeConfiguration(),
      session: makeSession()
    )

    let winner = try await client.push(expected)

    XCTAssertEqual(winner, expected)
  }

  func testClientKeepsQueueEligibleWhenServerIsUnavailable() async {
    PersonalSyncURLProtocol.requestHandler = { request in
      return (
        HTTPURLResponse(
          url: try XCTUnwrap(request.url),
          statusCode: 503,
          httpVersion: nil,
          headerFields: nil
        )!,
        Data()
      )
    }
    let client = PersonalSyncClient(
      configuration: makeConfiguration(),
      session: makeSession()
    )

    do {
      _ = try await client.push(makeRecord())
      XCTFail("Expected the unavailable response to fail")
    } catch {
      XCTAssertEqual(error as? PersonalSyncClientError, .httpStatus(503))
    }
  }

  private func makeConfiguration() -> PersonalSyncConfiguration {
    PersonalSyncConfiguration(
      projectURL: URL(string: "https://project.supabase.co")!,
      apiKey: "public-key",
      librarySecret: String(repeating: "s", count: 32)
    )
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PersonalSyncURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func makeRecord() -> PersonalSyncRecord {
    PersonalSyncRecord(
      itemKey: String(repeating: "a", count: 64),
      displayTitle: "Test Book",
      durationMs: 60_000,
      positionMs: 42_000,
      isFinished: false,
      eventAt: Date(timeIntervalSince1970: 1_777_777_777.123),
      sourceDeviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
  }

  private func makeItem(lastPlayDate: Date?) -> SimpleLibraryItem {
    SimpleLibraryItem(
      title: "Test Book",
      details: "",
      speed: 1,
      currentTime: 10,
      duration: 60,
      percentCompleted: 16.67,
      isFinished: false,
      relativePath: "Test Book.m4b",
      remoteURL: nil,
      artworkURL: nil,
      orderRank: 0,
      parentFolder: nil,
      originalFileName: "Test Book.m4b",
      lastPlayDate: lastPlayDate,
      type: .book,
      uuid: "test-book"
    )
  }

  private static func rpcData(for records: [PersonalSyncRecord]) -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .custom { date, encoder in
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      var container = encoder.singleValueContainer()
      try container.encode(formatter.string(from: date))
    }
    return try! encoder.encode(records)
  }

  private static func bodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody {
      return body
    }

    let stream = try XCTUnwrap(request.httpBodyStream)
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBufferPointer { pointer in
        stream.read(pointer.baseAddress!, maxLength: pointer.count)
      }
      if count < 0 {
        throw try XCTUnwrap(stream.streamError)
      }
      if count == 0 {
        return data
      }
      data.append(contentsOf: buffer.prefix(count))
    }
  }
}

private final class PersonalSyncURLProtocol: URLProtocol, @unchecked Sendable {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestHandler = Self.requestHandler else {
      XCTFail("PersonalSyncURLProtocol.requestHandler was not set")
      return
    }

    do {
      let (response, data) = try requestHandler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
