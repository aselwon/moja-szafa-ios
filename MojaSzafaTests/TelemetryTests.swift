import XCTest
@testable import MojaSzafa

private actor TelemetryFake: TelemetryRepository {
    var value = TelemetryPreferences.disabled
    var choices: [TelemetryChoice] = []
    var batches: [[TelemetryEvent]] = []
    var probes: [Bool] = []
    var failChoice = false
    var failIngest = false
    var replay: TelemetryPreferences?
    func set(_ value: TelemetryPreferences) { self.value = value }
    func failure(choice: Bool = false, ingest: Bool = false) { failChoice = choice; failIngest = ingest }
    func setReplay(_ value: TelemetryPreferences) { replay = value }
    func telemetryPreferences() async throws -> TelemetryPreferences { value }
    func telemetryChoose(_ choice: TelemetryChoice) async throws -> TelemetryPreferences {
        choices.append(choice)
        if failChoice { throw URLError(.timedOut) }
        if let replay { return replay }
        value = TelemetryPreferences(version: choice.baseVersion + 1, diagnostics: choice.diagnostics, product: choice.product, updatedAt: nil)
        return value
    }
    func telemetryIngest(version: Int64, events: [TelemetryEvent], probeActivation: Bool) async throws {
        batches.append(events); probes.append(probeActivation)
        if failIngest { throw URLError(.networkConnectionLost) }
        if version != value.version {
            throw APIv1.Failure(code: "version_conflict", message: "changed", requestID: UUID())
        }
    }
    func history() -> ([TelemetryChoice], [[TelemetryEvent]], [Bool]) { (choices, batches, probes) }
}

@MainActor
final class TelemetryTests: XCTestCase {
    private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("telemetry.json") }
    private func enabled(_ version: Int64 = 1) -> TelemetryPreferences {
        TelemetryPreferences(version: version, diagnostics: true, product: true, updatedAt: nil)
    }
    func testDefaultOptOutDoesNotCollectOrSend() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh(); await recorder.record(.session()); await recorder.flush()
        let history = await remote.history(); XCTAssertTrue(history.1.isEmpty)
        let window = await recorder.diagnosticWindow(); XCTAssertNil(window)
    }
    func testOfflineWithdrawalStopsCollectionAndRetriesSameChoiceAfterRelaunch() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); await remote.set(enabled())
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh()
        await remote.failure(choice: true)
        do { try await recorder.choose(diagnostics: false, product: false); XCTFail("Expected lost connection") } catch {}
        await recorder.record(.session()); await recorder.flush()
        let before = await remote.history(); XCTAssertTrue(before.1.isEmpty)
        let window = await recorder.diagnosticWindow(); XCTAssertNil(window)
        let relaunched = try TelemetryRecorder(repository: remote, journalURL: url)
        await remote.failure()
        try await relaunched.refresh(); await relaunched.flush()
        let after = await remote.history()
        XCTAssertEqual(after.0.count, 2); XCTAssertEqual(after.0[0], after.0[1]); XCTAssertTrue(after.1.isEmpty)
    }
    func testOldAcknowledgementCannotReenableWithdrawnConsent() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake()
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh()
        await remote.setReplay(enabled())
        await remote.set(TelemetryPreferences(version: 2, diagnostics: false, product: false, updatedAt: nil))
        try await recorder.choose(diagnostics: true, product: true)
        await recorder.record(.session()); await recorder.flush()
        let history = await remote.history(); XCTAssertTrue(history.1.isEmpty)
        let preferences = await recorder.preferences(); XCTAssertFalse(preferences.diagnostics)
    }
    func testFailedIngestKeepsStableIDsAcrossRelaunchAndRequiresFreshConsent() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); await remote.set(enabled())
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh(); await remote.failure(ingest: true); await recorder.flush()
        let first = await remote.history()
        let relaunched = try TelemetryRecorder(repository: remote, journalURL: url)
        await relaunched.flush()
        let unverified = await remote.history(); XCTAssertEqual(unverified.1.count, 1)
        try await relaunched.refresh(); await remote.failure(); await relaunched.flush()
        let after = await remote.history()
        XCTAssertEqual(after.1[1].first?.id, first.1[0].first?.id)
        XCTAssertTrue(after.2.allSatisfy { $0 })
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testServerConsentChangeFencesQueueAndInvalidationErasesJournal() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); await remote.set(enabled())
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh()
        await remote.set(TelemetryPreferences(version: 2, diagnostics: false, product: false, updatedAt: nil))
        await recorder.flush()
        let window = await recorder.diagnosticWindow(); XCTAssertNil(window)
        try await recorder.invalidate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await recorder.record(.session()); await recorder.flush()
        let history = await remote.history(); XCTAssertEqual(history.1.count, 1)
    }
    func testBoundedOutboxUsesBatchesOfTwenty() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); await remote.set(enabled())
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh()
        for _ in 0..<150 { await recorder.record(.session()) }
        for _ in 0..<6 { await recorder.flush() }
        let history = await remote.history()
        XCTAssertEqual(history.1.map(\.count), [20,20,20,20,20,0])
        XCTAssertEqual(Set(history.1.flatMap { $0 }.map(\.id)).count, 100)
    }
    func testRoutesAndErrorsNeverContainPrivateStrings() throws {
        XCTAssertNil(TelemetryEvent.latency(route: "https://example.com/private", outcome: .success, seconds: 1))
        XCTAssertNil(TelemetryEvent.latency(route: "api_v1_telemetry", outcome: .success, seconds: 1))
        XCTAssertNil(TelemetryEvent.latency(route: "api_v1_get", outcome: .success, seconds: .nan))
        let error = APIv1.Failure(code: "version_conflict", message: "secret garment", requestID: UUID())
        let event = try XCTUnwrap(TelemetryEvent.latency(route: "sync_cycle", kind: "sync", outcome: .classify(error), seconds: 0.123))
        let data = try JSONEncoder().encode(event)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        XCTAssertEqual(event.durationMs, 123); XCTAssertEqual(event.outcome, "conflict")
    }
    func testCrashSanitizerDropsRawFieldsAndSystemFramesAndDeduplicates() throws {
        let uuid = UUID()
        let json = """
        {"callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":"MojaSzafa","binaryUUID":"\(uuid)","offsetIntoBinaryTextSegment":123,"address":999,"rawFrame":"secret","subFrames":[{"binaryName":"libsystem","binaryUUID":"\(uuid)","offsetIntoBinaryTextSegment":4}]}]}]}}
        """
        let data = Data(json.utf8), date = Date(timeIntervalSince1970: 100)
        let event = try XCTUnwrap(CrashSanitizer.event(data: data, build: "42", architecture: "arm64", begin: date, end: date))
        XCTAssertEqual(event.frames, [TelemetryFrame(binaryUUID: uuid, offset: 123)])
        XCTAssertEqual(event, CrashSanitizer.event(data: data, build: "42", architecture: "arm64", begin: date, end: date))
        let wire = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        for privateField in ["secret", "address", "binaryName", "libsystem"] { XCTAssertFalse(wire.contains(privateField)) }
        XCTAssertNil(CrashSanitizer.event(data: data, build: "person@example.com", architecture: "arm64", begin: date, end: date))
        XCTAssertNil(CrashSanitizer.event(data: Data(json.replacingOccurrences(of: ":123", with: ":true").utf8), build: "42", architecture: "arm64", begin: date, end: date))
    }
}

private struct TelemetryTransport: APITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data("{\"data\":{\"value\":7},\"request_id\":\"00000000-0000-4000-8000-000000000001\"}".utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension TelemetryTests {
    func testActualRPCTransportRecordsOnlyFixedRouteOutcomeAndDuration() async throws {
        let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let remote = TelemetryFake(); await remote.set(enabled())
        let recorder = try TelemetryRecorder(repository: remote, journalURL: url)
        try await recorder.refresh()
        var client = try APIClient(baseURL: URL(string: "https://example.com")!, transport: TelemetryTransport()) { "private-token" }
        client.telemetry = recorder
        struct Output: Decodable, Sendable { let value: Int }
        let result: APIv1.Success<Output> = try await client.call("api_v1_test", ["name": "private-shirt"])
        XCTAssertEqual(result.data.value, 7)
        // Calling the telemetry method itself must never create a recursive event.
        let _: APIv1.Success<Output> = try await client.call("api_v1_telemetry", ["action": "get"])
        await recorder.flush()
        let history = await remote.history()
        let events = history.1.flatMap { $0 }.filter { $0.kind == "api" }
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.route, "api_v1_test")
        XCTAssertEqual(events.first?.outcome, "success")
        let data = try JSONEncoder().encode(events)
        let wire = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(wire.contains("private")); XCTAssertFalse(wire.contains("https"))
    }
}
