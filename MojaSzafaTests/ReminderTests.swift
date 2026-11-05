import XCTest
@testable import MojaSzafa

@MainActor
final class ReminderTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func plan(_ day: String, zone: String = "Europe/Warsaw", deleted: Bool = false, wearID: UUID? = nil) -> PlannedOutfit {
        PlannedOutfit(id: UUID(), version: 1, day: day, timezone: zone, deleted: deleted, outfit: Outfit(), wearID: wearID)
    }

    func testOptOutAndInvalidQuietHoursProduceNoRequests() {
        let now = date("2026-03-27T00:00:00Z")
        XCTAssertTrue(ReminderSchedule.requests(plans: [plan("2026-03-28")], settings: ReminderSettings(), now: now,
            timezone: .gmt, scope: "scope", generation: UUID()).isEmpty)
        var settings = ReminderSettings(); settings.wear = true; settings.quietEnd = settings.quietStart
        XCTAssertFalse(settings.valid)
        XCTAssertTrue(ReminderSchedule.requests(plans: [], settings: settings, now: now, timezone: .gmt, scope: "scope", generation: UUID()).isEmpty)
    }

    func testSpringDSTUsesCalendarDayAndMovesNonexistentQuietEndForward() {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        var settings = ReminderSettings(); settings.wear = true; settings.wearHour = 1; settings.quietEnd = 2
        let result = ReminderSchedule.requests(plans: [], settings: settings, now: date("2026-03-28T00:00:00Z"),
            timezone: zone, scope: "scope", generation: UUID())
        let transition = result.first { $0.day == "2026-03-29" }
        XCTAssertEqual(transition?.date, date("2026-03-29T01:00:00Z")) // 03:00 local; 02:00 does not exist.
        XCTAssertEqual(result.first { $0.day == "2026-03-30" }?.date, date("2026-03-30T00:00:00Z"))
    }

    func testFallRepeatedHourSchedulesOnceAndDaytimeQuietHoursWork() {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        var settings = ReminderSettings(); settings.wear = true; settings.wearHour = 2; settings.quietStart = 10; settings.quietEnd = 12
        let requests = ReminderSchedule.requests(plans: [], settings: settings, now: date("2026-10-24T00:00:00Z"),
            timezone: zone, scope: "scope", generation: UUID())
        XCTAssertEqual(requests.filter { $0.day == "2026-10-25" }.count, 1)
        XCTAssertEqual(requests.first { $0.day == "2026-10-25" }?.date, date("2026-10-25T00:00:00Z"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        XCTAssertEqual(ReminderSchedule.outsideQuietHours(date("2026-10-25T10:00:00Z"), settings: settings, calendar: calendar), date("2026-10-25T11:00:00Z"))
    }

    func testPlansKeepTheirTimezoneAndSkipDeletedConfirmedAndDuplicates() {
        var settings = ReminderSettings(); settings.plans = true; settings.quietStart = 22; settings.quietEnd = 1
        let tokyo = plan("2026-11-06", zone: "Asia/Tokyo")
        let requests = ReminderSchedule.requests(plans: [tokyo, tokyo, plan("2026-11-06", deleted: true), plan("2026-11-06", wearID: UUID())],
            settings: settings, now: date("2026-11-05T00:00:00Z"), timezone: TimeZone(identifier: "America/Los_Angeles")!, scope: "scope", generation: UUID())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.date, date("2026-11-05T23:00:00Z"))
        XCTAssertEqual(requests.first?.day, "2026-11-06")
    }

    func testHorizonAndPendingLimitAreBounded() {
        var settings = ReminderSettings(); settings.plans = true; settings.wear = true
        let plans = (0..<100).map { _ in plan("2026-11-06") } + [plan("2027-01-01")]
        let requests = ReminderSchedule.requests(plans: plans, settings: settings, now: date("2026-11-05T00:00:00Z"), timezone: .gmt, scope: "scope", generation: UUID())
        XCTAssertEqual(requests.count, 60)
        XCTAssertEqual(Set(requests.map(\.id)).count, 60)
        XCTAssertTrue(requests.allSatisfy { $0.date > date("2026-11-05T00:00:00Z") && $0.date < date("2026-11-19T00:00:00Z") })
    }

    func testDenialDoesNotEnableSettingsOrCallPlanner() async {
        let center = ReminderCenterFixture(); center.allowed = false; center.permissionResult = false
        let repository = ReminderPlannerFixture(); let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = ReminderModel(center: center)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        XCTAssertEqual(center.permissionRequests, 0)
        var settings = ReminderSettings(); settings.plans = true
        await model.apply(settings)
        XCTAssertEqual(center.permissionRequests, 1)
        XCTAssertFalse(model.settings.enabled)
        XCTAssertEqual(model.errorKey, "reminders.denied")
        let reads = await repository.reads
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testSettingsSurviveRelaunchButLogoutCancelsAndRemovesPreferences() async throws {
        let center = ReminderCenterFixture(); let folder = directory(); let account = UUID(); let repository = ReminderPlannerFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ReminderModel(center: center)
        first.sessionChanged(accountID: account, gateway: "one", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.wear = true
        await first.apply(settings)
        XCTAssertGreaterThan(center.requests.count, 0)
        let second = ReminderModel(center: center)
        second.sessionChanged(accountID: account, gateway: "one", repository: repository, directory: folder)
        XCTAssertEqual(second.settings, settings)
        second.sessionChanged(accountID: nil, gateway: "one", repository: repository, directory: folder)
        await Task.yield()
        XCTAssertTrue(center.requests.isEmpty)
        second.sessionChanged(accountID: account, gateway: "one", repository: repository, directory: folder)
        XCTAssertFalse(second.settings.enabled)
        XCTAssertNil(second.route)
    }

    func testLogoutDuringPendingAddCannotRestoreNotificationOrRoute() async {
        let center = ReminderCenterFixture(); center.suspendNextAdd = true
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ReminderPlannerFixture(); let model = ReminderModel(center: center)
        model.sessionChanged(accountID: UUID(), gateway: "one", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.wear = true
        let apply = Task { await model.apply(settings) }
        while center.suspended == nil { await Task.yield() }
        let old = center.inFlight!
        model.sessionChanged(accountID: nil, gateway: "one", repository: repository, directory: folder)
        center.suspended?.resume(); center.suspended = nil
        await apply.value
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(model.scheduledCount, 0)
        model.sessionChanged(accountID: UUID(), gateway: "one", repository: repository, directory: folder)
        model.receive(scope: old.scope, kind: "wear", day: old.day, timezone: old.timezone)
        XCTAssertNil(model.route)
    }

    func testTapValidatesScopeAndDateAndOnlyRoutesWithoutMutation() async {
        let center = ReminderCenterFixture(); let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ReminderPlannerFixture(); let model = ReminderModel(center: center)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.wear = true; await model.apply(settings)
        let request = center.requests.values.first!
        model.receive(scope: "foreign", kind: "wear", day: request.day, timezone: request.timezone)
        XCTAssertNil(model.route)
        model.receive(scope: request.scope, kind: "wear", day: "2026-02-31", timezone: request.timezone)
        XCTAssertNil(model.route)
        model.receive(scope: request.scope, kind: "wear", day: request.day, timezone: request.timezone)
        XCTAssertEqual(model.route?.kind, .wear)
        let writes = await repository.writes; XCTAssertEqual(writes, 0)
    }

    func testPlanRefreshReadsAllPagesAndCancelsStaleScheduleOnNetworkFailure() async {
        let center = ReminderCenterFixture(); let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let day = PlannerDay.string(Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        let repository = ReminderPlannerFixture(secondPage: plan(day, zone: TimeZone.current.identifier))
        let model = ReminderModel(center: center)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.plans = true
        await model.apply(settings)
        XCTAssertEqual(center.requests.count, 1)
        let reads = await repository.reads; XCTAssertEqual(reads, 2)
        await repository.fail()
        await model.refresh()
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(model.errorKey, "reminders.failed")
        XCTAssertEqual(model.scheduledCount, 0)
    }

    func testTurningOffCancelsAndNewGatewayDoesNotReuseOptIn() async {
        let center = ReminderCenterFixture(); let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ReminderPlannerFixture(); let account = UUID(); let model = ReminderModel(center: center)
        model.sessionChanged(accountID: account, gateway: "one", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.wear = true
        await model.apply(settings); XCTAssertFalse(center.requests.isEmpty)
        await model.apply(ReminderSettings()); XCTAssertTrue(center.requests.isEmpty)
        await model.apply(settings)
        model.sessionChanged(accountID: account, gateway: "two", repository: repository, directory: folder)
        XCTAssertFalse(model.settings.enabled)
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testPlannerMutationCancelsImmediatelyAndReschedulesAfterAcknowledgment() async {
        let center = ReminderCenterFixture(); let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ReminderPlannerFixture(); let model = ReminderModel(center: center)
        model.sessionChanged(accountID: UUID(), gateway: "test", repository: repository, directory: folder)
        var settings = ReminderSettings(); settings.wear = true; await model.apply(settings)
        model.planMutationStarted(); XCTAssertTrue(center.requests.isEmpty)
        await model.refresh(); XCTAssertTrue(center.requests.isEmpty)
        model.planMutationFinished()
        await model.refresh()
        // The asynchronous callback may replace this refresh; drain it explicitly.
        await Task.yield(); await model.refresh()
        XCTAssertGreaterThan(center.requests.count, 0)
    }
}

@MainActor
private final class ReminderCenterFixture: ReminderNotificationCenter {
    var allowed = true
    var permissionResult = true
    var permissionRequests = 0
    var requests: [String: ReminderRequest] = [:]
    var suspendNextAdd = false
    var suspended: CheckedContinuation<Void, Never>?
    var inFlight: ReminderRequest?
    func authorized() async -> Bool { allowed }
    func requestPermission() async throws -> Bool { permissionRequests += 1; allowed = permissionResult; return permissionResult }
    func clear() { requests = [:] }
    func remove(_ identifiers: [String]) { identifiers.forEach { requests.removeValue(forKey: $0) } }
    func add(_ request: ReminderRequest) async throws {
        if suspendNextAdd {
            suspendNextAdd = false; inFlight = request
            await withCheckedContinuation { suspended = $0 }
        }
        requests[request.id] = request
    }
}
private actor ReminderPlannerFixture: PlannerRepository {
    var reads = 0
    var writes = 0
    private let secondPage: PlannedOutfit?
    private let cursorID = UUID()
    private var failed = false
    init(secondPage: PlannedOutfit? = nil) { self.secondPage = secondPage }
    func fail() { failed = true }
    func plans(from: String, through: String, cursor: UUID?) async throws -> PlannerPage {
        reads += 1
        if failed { throw URLError(.notConnectedToInternet) }
        if let secondPage {
            return cursor == nil ? PlannerPage(items: [], nextCursor: cursorID) : PlannerPage(items: [secondPage], nextCursor: nil)
        }
        return PlannerPage(items: [], nextCursor: nil)
    }
    func changePlan(_ request: PlannerMutation) async throws -> PlannedOutfit { writes += 1; throw APIClientError.invalidRequest }
}
