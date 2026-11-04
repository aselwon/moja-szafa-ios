import XCTest
@testable import MojaSzafa

@MainActor
final class PlannerTests: XCTestCase {
    private func journal() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pending.json") }

    func testAmbiguousConfirmationSurvivesRelaunchWithoutNewOperation() async throws {
        let url = journal(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = PlannerFixture(failFirst: true)
        let request = PlannerMutation(action: .confirm, id: UUID(), baseVersion: 1, outfitVersion: 1)
        let first = PlannerModel(repository: repository, journalURL: url)
        let accepted = await first.change(request)
        XCTAssertFalse(accepted)
        XCTAssertEqual(first.pending, request)
        let second = PlannerModel(repository: repository, journalURL: url)
        XCTAssertEqual(second.pending, request)
        await second.retry()
        let calls = await repository.requests
        XCTAssertEqual(calls, [request, request])
        XCTAssertNil(second.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPendingMutationBlocksDifferentIntentAndAccountJournalIsSeparate() async {
        let url = journal(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = PlannerFixture(failFirst: true)
        let model = PlannerModel(repository: repository, journalURL: url)
        _ = await model.change(PlannerMutation(action: .confirm, id: UUID(), baseVersion: 1, outfitVersion: 1))
        let different = await model.change(PlannerMutation(action: .delete, id: UUID(), baseVersion: 1))
        XCTAssertFalse(different)
        let calls = await repository.requests
        XCTAssertEqual(calls.count, 1)
        let other = PlannerModel(repository: repository, journalURL: journal())
        XCTAssertNil(other.pending)
    }

    func testCorruptJournalFailsClosed() async throws {
        let url = journal(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: url)
        let repository = PlannerFixture()
        let model = PlannerModel(repository: repository, journalURL: url)
        let accepted = await model.change(PlannerMutation(action: .delete, id: UUID(), baseVersion: 1))
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.errorKey, "planner.journalFailed")
        let calls = await repository.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func testDeleteUndoIsRestoreAndDoesNotIssueWearConfirmation() async {
        let repository = PlannerFixture()
        let model = PlannerModel(repository: repository)
        _ = await model.change(PlannerMutation(action: .delete, id: UUID(), baseVersion: 1))
        XCTAssertEqual(model.undo?.action, .restore)
        await model.undoLast()
        let calls = await repository.requests
        XCTAssertEqual(calls.map(\.action), [.delete, .restore])
    }

    func testFutureDateCannotBeConfirmedAndDayDoesNotShiftAcrossTimezones() {
        let instant = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
        XCTAssertEqual(PlannerDay.string(instant, timezone: "Pacific/Honolulu"), "2025-12-31")
        XCTAssertEqual(PlannerDay.string(instant, timezone: "Asia/Tokyo"), "2026-01-01")
        let plan = PlannedOutfit(id: UUID(), version: 1, day: "9999-12-31", timezone: "Pacific/Honolulu", deleted: false, outfit: Outfit(), wearID: nil)
        XCTAssertFalse(plan.canConfirm)
    }

    func testLatestWeekWinsWhenOldRequestFinishesLast() async {
        let repository = SuspendedPlannerFixture()
        let model = PlannerModel(repository: repository)
        let first = Task { await model.load(from: "2026-01-01", through: "2026-01-07") }
        while !(await repository.hasFirst) { await Task.yield() }
        await model.load(from: "2026-01-08", through: "2026-01-14")
        XCTAssertEqual(model.items.first?.day, "2026-01-08")
        XCTAssertFalse(model.loading)
        await repository.finishFirst()
        await first.value
        XCTAssertEqual(model.items.first?.day, "2026-01-08")
        XCTAssertFalse(model.loading)
    }

    func testMutationWireOmitsFieldsNotAllowedByConfirmContract() throws {
        let request = PlannerMutation(action: .confirm, id: UUID(), baseVersion: 2, outfitVersion: 3)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["action", "operationID", "id", "baseVersion", "outfitVersion"]))
    }
}

private actor PlannerFixture: PlannerRepository {
    var requests: [PlannerMutation] = []
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage { PlannerPage(items: [], nextCursor: nil) }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit {
        requests.append(request)
        if failFirst && requests.count == 1 { throw URLError(.timedOut) }
        return PlannedOutfit(id: request.id, version: request.baseVersion + 1, day: request.day ?? "2026-01-01", timezone: request.timezone ?? "UTC", deleted: request.action == .delete, outfit: Outfit(), wearID: request.action == .confirm ? UUID() : nil)
    }
}

private actor SuspendedPlannerFixture: PlannerRepository {
    private var first: CheckedContinuation<PlannerPage, Never>?
    var hasFirst: Bool { first != nil }
    private func plan(_ day: String) -> PlannedOutfit {
        PlannedOutfit(id: UUID(), version: 1, day: day, timezone: "UTC", deleted: false, outfit: Outfit(), wearID: nil)
    }
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage {
        if from == "2026-01-01" { return await withCheckedContinuation { first = $0 } }
        return PlannerPage(items: [plan(from)], nextCursor: nil)
    }
    func finishFirst() { first?.resume(returning: PlannerPage(items: [plan("2026-01-01")], nextCursor: nil)); first = nil }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit { throw URLError(.unsupportedURL) }
}
