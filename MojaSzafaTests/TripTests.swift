import XCTest
@testable import MojaSzafa

@MainActor
final class TripTests: XCTestCase {
    func testUniqueItemBudgetAllowsIntentionalRepeatsAcrossEveryDay() {
        let dress = Garment(id: UUID(), name: "Dress", category: .dress)
        let shoes = Garment(id: UUID(), name: "Shoes", category: .shoes)
        let outfit = Outfit(version: 1, name: "Travel", garments: [dress, shoes])
        let days = TripPlanner.days(from: "2026-11-01", through: "2026-11-04")
        let result = TripPlanner.suggest(days: days, outfits: [outfit], maxItems: 2)
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.allSatisfy { $0.outfitID == outfit.id })
        XCTAssertEqual(Set(result.map(\.day)).count, 4)
    }
    func testTooSmallBudgetAndUnavailableWardrobeLeaveExplicitUnfilledDays() {
        let outfit = Outfit(version: 1, name: "Travel", garments: [Garment(id: UUID(), name: "Dress"), Garment(id: UUID(), name: "Shoes")])
        XCTAssertNil(TripPlanner.suggest(days: ["2026-11-01"], outfits: [outfit], maxItems: 1)[0].outfitID)
        var unavailable = outfit; unavailable.garments[0].availability = .laundry
        XCTAssertNil(TripPlanner.suggest(days: ["2026-11-01"], outfits: [unavailable], maxItems: 100)[0].outfitID)
    }
    func testCalendarDaysAreBoundedAndDoNotSkipDaylightSavingBoundary() {
        XCTAssertEqual(TripPlanner.days(from: "2026-03-28", through: "2026-03-30"), ["2026-03-28", "2026-03-29", "2026-03-30"])
        XCTAssertTrue(TripPlanner.days(from: "2026-11-02", through: "2026-11-01").isEmpty)
        XCTAssertTrue(TripPlanner.days(from: "2026-11-01", through: "2026-12-01").isEmpty)
    }
    func testUnfilledDayHasExplicitNullSelectionOnWire() throws {
        let data = try JSONEncoder().encode(TripChoice(day: "2026-11-01"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["outfitID"] is NSNull)
        XCTAssertTrue(object["outfitVersion"] is NSNull)
    }
    func testPackingTimeoutReplaysIdenticalIntentAfterRelaunch() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = TripFixture(failFirst: true)
        let request = TripMutation(action: .pack, id: UUID(), baseVersion: 1, garmentID: UUID(), packed: true)
        let first = TripModel(repository: repository, journalURL: url)
        let accepted = await first.change(request)
        XCTAssertFalse(accepted)
        let second = TripModel(repository: repository, journalURL: url)
        XCTAssertEqual(second.pending, request)
        let retried = await second.change(request)
        XCTAssertTrue(retried)
        XCTAssertNil(second.pending)
        let requests = await repository.requests
        XCTAssertEqual(requests, [request, request])
        XCTAssertEqual(second.undoPacking?.action, .pack)
        XCTAssertEqual(second.undoPacking?.packed, false)
    }
    func testAmbiguousSaveBlocksDifferentIntent() async {
        let repository = TripFixture(failFirst: true)
        let model = TripModel(repository: repository)
        _ = await model.change(TripMutation(action: .pack, id: UUID(), baseVersion: 1, garmentID: UUID(), packed: true))
        let different = await model.change(TripMutation(action: .pack, id: UUID(), baseVersion: 1, garmentID: UUID(), packed: false))
        XCTAssertFalse(different)
        let requests = await repository.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testOldTripResponseCannotReplaceNewSelection() async {
        let repository = SuspendedTripFixture()
        let firstID = await repository.firstID
        let secondID = UUID()
        let model = TripModel(repository: repository)
        let first = Task { await model.load(id: firstID) }
        while !(await repository.waiting) { await Task.yield() }
        await model.load(id: secondID)
        await repository.finish()
        await first.value
        XCTAssertEqual(model.current?.id, secondID)
        XCTAssertFalse(model.loading)
    }
    func testCorruptJournalFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid".utf8).write(to: url)
        let repository = TripFixture()
        let model = TripModel(repository: repository, journalURL: url)
        let accepted = await model.change(TripMutation(action: .pack, id: UUID(), baseVersion: 1, garmentID: UUID(), packed: true))
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.errorKey, "trips.journalFailed")
        let requests = await repository.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
private func fixtureTrip(id: UUID, version: Int64 = 1) -> TripPlan {
    TripPlan(id: id, version: version, destination: "Warsaw", startsOn: "2026-11-01", endsOn: "2026-11-01", timezone: "Europe/Warsaw", occasions: ["Work"], maxItems: 3, days: [], packing: [])
}
private actor TripFixture: TripRepository {
    var requests: [TripMutation] = []
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func trips(cursor: UUID?) async throws -> TripPage { TripPage(items: [], nextCursor: nil) }
    func trip(id: UUID) async throws -> TripPlan { fixtureTrip(id: id) }
    func changeTrip(_ request: TripMutation) async throws -> TripPlan {
        requests.append(request)
        if failFirst && requests.count == 1 { throw URLError(.timedOut) }
        return fixtureTrip(id: request.id, version: request.baseVersion + 1)
    }
}
private actor SuspendedTripFixture: TripRepository {
    let firstID = UUID()
    private var continuation: CheckedContinuation<TripPlan, Never>?
    var waiting: Bool { continuation != nil }
    func trips(cursor: UUID?) async throws -> TripPage { TripPage(items: [], nextCursor: nil) }
    func trip(id: UUID) async throws -> TripPlan {
        if id == firstID { return await withCheckedContinuation { continuation = $0 } }
        return fixtureTrip(id: id)
    }
    func finish() { continuation?.resume(returning: fixtureTrip(id: firstID)); continuation = nil }
    func changeTrip(_ request: TripMutation) async throws -> TripPlan { throw URLError(.unsupportedURL) }
}
