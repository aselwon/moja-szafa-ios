import XCTest
@testable import MojaSzafa

@MainActor
final class WidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_836_800) // fixed fixture instant
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func snapshot(now: Date, count: Int = 2, zone: TimeZone = .gmt) -> WardrobeWidgetSnapshot {
        WardrobeWidgetSnapshot(version: 1, day: WardrobeWidgetSnapshot.dayString(now, timezone: zone), timezone: zone.identifier,
            plannedCount: count, generatedAt: now, expiresAt: now.addingTimeInterval(900))
    }
    func testSharedPayloadContainsOnlyAggregateAndFreshnessFields() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(now: now))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["version", "day", "timezone", "plannedCount", "generatedAt", "expiresAt"]))
    }
    func testExpiredWrongZoneFutureClockAndMalformedCountsFailClosed() {
        XCTAssertTrue(snapshot(now: now).isUsable(now: now, timezone: .gmt))
        XCTAssertFalse(snapshot(now: now).isUsable(now: now.addingTimeInterval(900), timezone: .gmt))
        XCTAssertFalse(snapshot(now: now).isUsable(now: now, timezone: TimeZone(identifier: "Asia/Tokyo")!))
        XCTAssertFalse(snapshot(now: now.addingTimeInterval(61)).isUsable(now: now, timezone: .gmt))
        XCTAssertFalse(snapshot(now: now, count: -1).isUsable(now: now, timezone: .gmt))
        XCTAssertFalse(snapshot(now: now, count: 10_001).isUsable(now: now, timezone: .gmt))
    }
    func testStoreRoundTripCorruptionExpiryAndErasure() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetSnapshotStore(directory: folder)
        try store.write(snapshot(now: now))
        XCTAssertEqual(store.read(now: now, timezone: .gmt)?.plannedCount, 2)
        XCTAssertNil(store.read(now: now.addingTimeInterval(901), timezone: .gmt))
        let file = folder.appendingPathComponent("today-widget-v1.json")
        try Data("invalid".utf8).write(to: file)
        XCTAssertNil(store.read(now: now, timezone: .gmt))
        try store.write(snapshot(now: now)); try store.clear()
        XCTAssertNil(store.read(now: now, timezone: .gmt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRoutingRejectsForeignSchemesAndParameters() {
        XCTAssertTrue(WardrobeWidgetIdentity.accepts(URL(string: "mojaszafa-dev://wear")!, expectedScheme: "mojaszafa-dev"))
        for value in ["mojaszafa://wear", "https://wear", "mojaszafa-dev://wear?confirm=true", "mojaszafa-dev://wear/path",
                      "mojaszafa-dev://wear#fragment", "mojaszafa-dev://user@wear", "mojaszafa-dev://wear:80"] {
            XCTAssertFalse(WardrobeWidgetIdentity.accepts(URL(string: value)!, expectedScheme: "mojaszafa-dev"), value)
        }
    }
    func testOptInCountsAllPagesWithoutWritingWearAndDisablingClears() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetSnapshotStore(directory: folder.appendingPathComponent("shared"))
        let repository = WidgetPlannerFixture()
        let model = WardrobeWidgetModel(store: store)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        await model.refresh(now: now, timezone: .gmt)
        let initialReads = await repository.reads; XCTAssertEqual(initialReads, 0)
        await model.setEnabled(true)
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.plannedCount, 2)
        XCTAssertNotNil(store.read())
        let writes = await repository.writes; XCTAssertEqual(writes, 0)
        await model.setEnabled(false)
        XCTAssertNil(store.read())
        XCTAssertFalse(model.enabled)
    }
    func testLogoutWhileFetchSuspendedCannotRestoreOldSnapshot() async {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetSnapshotStore(directory: folder.appendingPathComponent("shared"))
        let repository = WidgetPlannerFixture(suspend: true)
        let model = WardrobeWidgetModel(store: store)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        let enable = Task { await model.setEnabled(true) }
        while !(await repository.waiting) { await Task.yield() }
        model.sessionChanged(accountID: nil, gateway: "test", repository: repository, directory: folder)
        await repository.resume()
        await enable.value
        XCTAssertNil(store.read())
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.plannedCount)
    }
    func testUserCanDisableWhileNetworkReadIsSuspended() async {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetSnapshotStore(directory: folder.appendingPathComponent("shared"))
        let repository = WidgetPlannerFixture(suspend: true)
        let model = WardrobeWidgetModel(store: store)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        let enable = Task { await model.setEnabled(true) }
        while !(await repository.waiting) { await Task.yield() }
        await model.setEnabled(false)
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy)
        await repository.resume(); await enable.value
        XCTAssertNil(store.read())
    }
    func testIntentQueuesConfirmationUntilLoginAndNeverMutatesData() async throws {
        _ = WearIntentRoute.consume()
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let repository = WidgetPlannerFixture()
        let model = WardrobeWidgetModel(store: WidgetSnapshotStore(directory: folder.appendingPathComponent("shared")))
        model.sessionChanged(accountID: nil, gateway: "test", repository: repository, directory: folder)
        _ = try await ConfirmWearIntent().perform()
        model.consumeIntent(); XCTAssertFalse(model.showWearConfirmation)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        XCTAssertTrue(model.showWearConfirmation)
        let writes = await repository.writes; let reads = await repository.reads
        XCTAssertEqual(writes, 0); XCTAssertEqual(reads, 0)
        model.sessionChanged(accountID: nil, gateway: "test", repository: repository, directory: folder)
        XCTAssertFalse(model.showWearConfirmation)
    }
    func testUnavailableGroupDoesNotPretendOptInSucceeded() async {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = WardrobeWidgetModel(store: WidgetSnapshotStore(directory: nil))
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: WidgetPlannerFixture(), directory: folder)
        await model.setEnabled(true)
        XCTAssertFalse(model.available); XCTAssertFalse(model.enabled)
        XCTAssertEqual(model.errorKey, "widget.unavailable")
    }
}

private actor WidgetPlannerFixture: PlannerRepository {
    var reads = 0
    var writes = 0
    private var suspend: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    private let firstID = UUID(), secondID = UUID(), cursorID = UUID()
    init(suspend: Bool = false) { self.suspend = suspend }
    func resume() { continuation?.resume(); continuation = nil }
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage {
        reads += 1
        if suspend { suspend = false; await withCheckedContinuation { continuation = $0 } }
        let a = PlannedOutfit(id: firstID, version: 1, day: from, timezone: TimeZone.current.identifier, deleted: false, outfit: Outfit(), wearID: nil)
        let b = PlannedOutfit(id: secondID, version: 1, day: from, timezone: TimeZone.current.identifier, deleted: false, outfit: Outfit(), wearID: nil)
        let deleted = PlannedOutfit(id: UUID(), version: 1, day: from, timezone: TimeZone.current.identifier, deleted: true, outfit: Outfit(), wearID: nil)
        return cursor == nil ? PlannerPage(items: [a, deleted], nextCursor: cursorID) : PlannerPage(items: [a, b], nextCursor: nil)
    }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit { writes += 1; throw APIClientError.invalidRequest }
}
