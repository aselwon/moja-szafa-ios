import XCTest
@testable import MojaSzafa

@MainActor
final class OfflineStoreTests: XCTestCase {
    private func database() -> OfflineDatabase {
        OfflineDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.sqlite"))
    }
    private let fields = APIv1.GarmentFields(name: "Shirt", category: .top, priceGrosz: 80000, availability: .available)

    func testInitialHistoryOfflineReplayAndOverlapConfirmation() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await store.recordWear(wornOn: "2026-01-02", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await store.synchronize()
        let history = InitialWearHistory(count: 9, startDate: "2026-01-02")
        do { _ = try await store.setInitialHistory(id: id, history: history, confirmOverlap: false); XCTFail("Unconfirmed overlap") }
        catch { XCTAssertEqual(error as? APIClientError, .invalidRequest) }
        _ = try await store.setInitialHistory(id: id, history: history, confirmOverlap: true)
        let restarted = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let local = try await restarted.detail(id: id)
        XCTAssertEqual(local.costPerWear.wearDays, 10)
        XCTAssertTrue(local.costPerWear.isEstimated)
        XCTAssertEqual(local.wornOn.count, 2)
        await remote.timeoutNextWrite()
        do { try await restarted.synchronize(); XCTFail("Expected lost response") } catch is URLError {}
        do { _ = try await restarted.setInitialHistory(id: id, history: nil, confirmOverlap: false); XCTFail("Sent intent is immutable") }
        catch { XCTAssertEqual(error as? OfflineError, .pendingChange) }
        let replay = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        try await replay.synchronize(now: .distantFuture)
        let requests = await remote.initialRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        _ = try await replay.setInitialHistory(id: id, history: nil, confirmOverlap: false)
        try await replay.synchronize(now: .distantFuture)
        let cleared = try await replay.detail(id: id)
        XCTAssertEqual(cleared.costPerWear.wearDays, 2)
        XCTAssertFalse(cleared.costPerWear.isEstimated)
        XCTAssertEqual(cleared.wornOn, local.wornOn)
        let clearData = await remote.initialRequests.last!
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: clearData) as? [String: Any])
        XCTAssertTrue(encoded["history"] is NSNull)
    }

    func testInitialHistoryConflictCanDiscardWithoutChangingDiary() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.synchronize()
        _ = try await store.setInitialHistory(id: id, history: InitialWearHistory(count: 5, startDate: "2026-01-01"), confirmOverlap: false)
        await remote.change(id: id, deleted: false)
        do { try await store.synchronize(); XCTFail("Stale estimate must conflict") } catch let error as APIv1.Failure { XCTAssertEqual(error.code, "version_conflict") }
        try await store.discardInitialHistoryConflict(id: id)
        let detail = try await store.detail(id: id)
        XCTAssertNil(detail.garment.initialWearHistory)
        XCTAssertTrue(detail.wornOn.isEmpty)
        let status = await store.status()
        XCTAssertTrue(status.outbox.isEmpty)
    }

    func testPermanentDeletionSurvivesRestartAndStaleSnapshot() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.synchronize()
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await store.deleteGarment(id: id)
        let restarted = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        // Remote delete is unavailable: the live server snapshot must not revive it.
        do { try await restarted.synchronize(); XCTFail("Expected unavailable deletion") } catch {}
        let state = await restarted.status()
        XCTAssertTrue(state.garments.first { $0.id == id }!.deleted)
        XCTAssertTrue(state.wears.allSatisfy { !$0.garmentIDs.contains(id) })
        XCTAssertEqual(state.outbox.filter { $0.deletion != nil }.count, 1)
        do { try await restarted.saveGarment(id: id, fields: fields); XCTFail("Revived tombstone") }
        catch { XCTAssertEqual(error as? OfflineError, .conflict) }
    }

    func testDeletingGarmentPreservesUnsentWearEditBaseVersionAfterRestart() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let removed = try await store.saveGarment(fields: fields)
        let retained = try await store.saveGarment(fields: fields)
        let wearID = try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [removed, retained])
        try await store.synchronize()
        let initial = await store.status()
        let saved = try XCTUnwrap(initial.wears.first { $0.id == wearID })
        XCTAssertGreaterThan(saved.version, 0)
        try await store.editWear(SyncWear(id: saved.id, version: saved.version, deleted: false,
            wornOn: "2026-01-02", timezone: saved.timezone, garmentIDs: saved.garmentIDs))
        let before = await store.status()
        let original = try XCTUnwrap(before.outbox.first { $0.wear != nil }?.wear)
        try await store.deleteGarment(id: removed)
        let restarted = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let after = await restarted.status()
        let pending = try XCTUnwrap(after.outbox.first { $0.wear != nil })
        let edited = try XCTUnwrap(pending.wear)
        XCTAssertFalse(pending.sent)
        XCTAssertEqual(edited.operationID, original.operationID)
        XCTAssertEqual(edited.wear.version, saved.version)
        XCTAssertEqual(edited.wear.garmentIDs, [retained])
        XCTAssertEqual(edited.wear.wornOn, "2026-01-02")
        // The server still recognizes this as an edit of the existing event.
        let accepted = try await remote.save(edited)
        XCTAssertEqual(accepted.version, saved.version + 1)
        let counts = await remote.counts()
        XCTAssertEqual(counts[1], 1)
    }

    func testDeletionWinsOverInFlightSave() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SuspendedSyncRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        let sync = Task { try await store.synchronize() }
        await remote.waitUntilSaving()
        try await store.deleteGarment(id: id)
        await remote.finish()
        try await sync.value
        let state = await store.status()
        XCTAssertTrue(state.garments.first { $0.id == id }!.deleted)
        XCTAssertEqual(state.outbox.filter { $0.deletion != nil }.count, 1)
    }

    func testStatusSurvivesRestartAndReachesSecondDeviceWithoutChangingHistoryOrPrice() async throws {
        let firstDB = database(), secondDB = database()
        defer {
            try? FileManager.default.removeItem(at: firstDB.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondDB.url.deletingLastPathComponent())
        }
        let remote = SyncTestRemote()
        let first = try OfflineStore(accountID: remote.accountID, database: firstDB, remote: remote)
        let second = try OfflineStore(accountID: remote.accountID, database: secondDB, remote: remote)
        let id = try await first.saveGarment(fields: fields)
        try await first.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await first.synchronize()
        for availability in APIv1.Availability.allCases {
            let local = try await first.setStatus(id: id, availability: availability, archived: true)
            XCTAssertTrue(local.garment.archived)
            let restarted = try OfflineStore(accountID: remote.accountID, database: firstDB, remote: remote)
            let restored = try await restarted.detail(id: id)
            XCTAssertTrue(restored.garment.archived)
            XCTAssertEqual(restored.garment.availability, availability)
            try await first.synchronize()
            try await second.synchronize()
            let detail = try await second.detail(id: id)
            XCTAssertEqual(detail.garment.availability, availability)
            XCTAssertTrue(detail.garment.archived)
            XCTAssertEqual(detail.garment.priceGrosz, 80000)
            XCTAssertEqual(detail.wornOn, ["2026-01-01"])
        }
        _ = try await first.setStatus(id: id, availability: .laundry, archived: false)
        try await first.synchronize()
        try await second.synchronize()
        let unarchived = try await second.detail(id: id)
        XCTAssertFalse(unarchived.garment.archived)
        XCTAssertEqual(unarchived.garment.availability, .laundry)
        XCTAssertEqual(unarchived.wornOn.count, 1)
    }

    func testArchiveConflictRequiresResolutionAndTimeoutReplaysSameIntent() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.synchronize()
        _ = try await store.setStatus(id: id, availability: .laundry, archived: true)
        await remote.change(id: id, deleted: false)
        do { try await store.synchronize(); XCTFail("Stale version must conflict") }
        catch let error as APIv1.Failure { XCTAssertEqual(error.code, "version_conflict") }
        try await store.resolveGarment(id: id, keepLocal: true)
        await remote.timeoutNextWrite()
        do { try await store.synchronize(); XCTFail("Expected ambiguous timeout") } catch is URLError {}
        let restarted = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        try await restarted.synchronize(now: .distantFuture)
        let requests = await remote.requests
        XCTAssertEqual(requests[requests.count - 1], requests[requests.count - 2])
        let detail = try await restarted.detail(id: id)
        XCTAssertTrue(detail.garment.archived)
        XCTAssertEqual(detail.garment.availability, .laundry)
    }

    func testOfflineCreateEditWearSurviveRestartAndSyncWithoutDuplicateDays() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let account = remote.accountID
        let store = try OfflineStore(accountID: account, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        let edited = APIv1.GarmentFields(name: "Edited", category: .top, priceGrosz: 0, availability: .available)
        try await store.saveGarment(id: id, fields: edited)
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        let restored = try OfflineStore(accountID: account, database: db, remote: remote)
        let offline = await restored.status()
        XCTAssertEqual(offline.garments.first?.fields.name, "Edited")
        XCTAssertEqual(offline.outbox.count, 3)
        let days = await restored.wearDays(for: id)
        XCTAssertEqual(days, 1)
        try await restored.synchronize()
        try await restored.synchronize()
        let synced = await restored.status()
        XCTAssertTrue(synced.outbox.isEmpty)
        XCTAssertEqual(synced.garments.first?.version, 1)
        let counts = await remote.counts()
        XCTAssertEqual(counts, [1, 2])
        XCTAssertThrowsError(try OfflineStore(accountID: UUID(), database: db, remote: remote))
    }

    func testCommitThenTimeoutReplaysSameOperationAfterRestart() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let account = remote.accountID
        let store = try OfflineStore(accountID: account, database: db, remote: remote)
        try await store.saveGarment(fields: fields)
        await remote.timeoutNextWrite()
        do { try await store.synchronize(); XCTFail("Expected timeout") } catch is URLError {}
        let pending = await store.status().outbox
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.attempts, 1)
        let restored = try OfflineStore(accountID: account, database: db, remote: remote)
        try await restored.synchronize(now: .distantPast)
        let beforeRetry = await remote.requests.count
        XCTAssertEqual(beforeRetry, 1)
        try await restored.synchronize(now: .distantFuture)
        let requests = await remote.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        let result = await restored.status()
        XCTAssertTrue(result.outbox.isEmpty)
        XCTAssertEqual(result.garments.first?.version, 1)
    }

    func testWearCommitThenTimeoutRetainsEventIdentity() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.synchronize()
        let eventID = try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        await remote.timeoutNextWear()
        do { try await store.synchronize(); XCTFail("Expected timeout") } catch is URLError {}
        let restored = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        try await restored.synchronize(now: .distantFuture)
        let state = await restored.status()
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(state.wears.map(\.id), [eventID])
        let counts = await remote.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testWearEditSurvivesRestartAndTimeoutWithoutDuplicateDays() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let shirt = try await store.saveGarment(fields: fields)
        let shoes = try await store.saveGarment(fields: fields)
        let first = try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [shirt])
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [shirt, shoes])
        try await store.synchronize()
        let edited = SyncWear(id: first, version: 1, deleted: false, wornOn: "2026-01-02",
                              timezone: "Europe/Warsaw", garmentIDs: [shoes])
        try await store.editWear(edited)
        let local = await store.status()
        XCTAssertEqual(local.wears.first { $0.id == first }, edited)
        let restored = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        await remote.timeoutNextWear()
        do { try await restored.synchronize(); XCTFail("Expected timeout") } catch is URLError {}
        let pending = await restored.status()
        XCTAssertEqual(pending.wears.first { $0.id == first }, edited, "Pull must not erase a pending edit")
        do { try await restored.editWear(edited); XCTFail("In-flight intent is immutable") }
        catch { XCTAssertEqual(error as? OfflineError, .pendingChange) }
        try await restored.synchronize(now: .distantFuture)
        let saved = await restored.status()
        XCTAssertTrue(saved.outbox.isEmpty)
        XCTAssertEqual(saved.wears.count, 2)
        XCTAssertEqual(saved.wears.first { $0.id == first }?.version, 2)
        let shirtDays = await restored.wearDays(for: shirt)
        let shoeDays = await restored.wearDays(for: shoes)
        XCTAssertEqual(shirtDays, 1, "Other event still contributes the shared day")
        XCTAssertEqual(shoeDays, 2)
        let requests = await remote.wearRequests
        XCTAssertEqual(requests.suffix(2).first, requests.last, "Retry must preserve the exact payload")
    }

    func testWearConflictResolutionAndTombstone() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let garment = try await store.saveGarment(fields: fields)
        let id = try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [garment])
        try await store.synchronize()
        let edit = SyncWear(id: id, version: 1, deleted: false, wornOn: "2026-01-02", timezone: "Europe/Warsaw", garmentIDs: [garment])
        try await store.editWear(edit)
        await remote.changeWear(id: id, deleted: false)
        do { try await store.synchronize(); XCTFail("Stale version") } catch is APIv1.Failure {}
        let conflicted = await store.status()
        XCTAssertEqual(conflicted.outbox.first?.failure, "version_conflict")
        try await store.resolveWear(id: id, keepLocal: true)
        let resolved = await store.status()
        XCTAssertNotEqual(resolved.outbox.first?.id, conflicted.outbox.first?.id)
        XCTAssertEqual(resolved.wears.first?.version, 2)
        try await store.synchronize()
        let current = await store.status().wears[0]
        try await store.editWear(current)
        await remote.changeWear(id: id, deleted: true)
        try await store.synchronize()
        let tombstone = await store.status()
        XCTAssertEqual(tombstone.wears.first?.deleted, true)
        do { try await store.resolveWear(id: id, keepLocal: true); XCTFail("Cannot revive tombstone") }
        catch { XCTAssertEqual(error as? OfflineError, .conflict) }
        try await store.resolveWear(id: id, keepLocal: false)
        let accepted = await store.status()
        XCTAssertTrue(accepted.outbox.isEmpty)
    }

    func testWearInvalidEditAndDiskFailureAreAtomic() async throws {
        let db = database()
        let directory = db.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let garment = try await store.saveGarment(fields: fields)
        let id = UUID()
        try await store.recordWear(id: id, wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [garment])
        try await store.recordWear(id: id, wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [garment])
        let before = await store.status()
        XCTAssertEqual(before.wears.count, 1)
        for (day, ids) in [("2999-01-01", [garment]), ("2026-02-30", [garment]), ("2026-01-02", [UUID()])] {
            do {
                try await store.editWear(SyncWear(id: id, version: 0, deleted: false, wornOn: day,
                                                  timezone: "Europe/Warsaw", garmentIDs: ids))
                XCTFail("Invalid edit")
            } catch { XCTAssertEqual(error as? APIClientError, .invalidRequest) }
        }
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        do {
            try await store.editWear(SyncWear(id: id, version: 0, deleted: false, wornOn: "2026-01-02",
                                              timezone: "Europe/Warsaw", garmentIDs: [garment]))
            XCTFail("Expected storage failure")
        } catch { }
        let after = await store.status()
        XCTAssertEqual(after.wears, before.wears)
        XCTAssertEqual(after.outbox.map(\.id), before.outbox.map(\.id))
    }

    func testWearDateValidationUsesRecordedTimezone() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-01-01T12:30:00Z")!
        let id = UUID()
        let eastern = SyncWear(id: UUID(), version: 0, deleted: false, wornOn: "2026-01-02",
                               timezone: "Pacific/Kiritimati", garmentIDs: [id])
        XCTAssertNoThrow(try eastern.validate(now: instant))
        let western = SyncWear(id: eastern.id, version: 0, deleted: false, wornOn: eastern.wornOn,
                               timezone: "Pacific/Honolulu", garmentIDs: [id])
        XCTAssertThrowsError(try western.validate(now: instant))
    }

    func testConflictRequiresExplicitResolutionAndTombstoneWins() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let id = try await store.saveGarment(fields: fields)
        try await store.synchronize()
        try await store.saveGarment(id: id, fields: fields)
        await remote.change(id: id, deleted: false)
        do { try await store.synchronize(); XCTFail("Expected conflict") } catch is APIv1.Failure {}
        let conflict = await store.status()
        XCTAssertEqual(conflict.outbox.first?.failure, "version_conflict")
        let oldID = conflict.outbox.first?.id
        try await store.resolveGarment(id: id, keepLocal: true)
        let resolved = await store.status()
        XCTAssertNotEqual(resolved.outbox.first?.id, oldID)
        XCTAssertEqual(resolved.outbox.first?.garment?.baseVersion, 2)
        try await store.synchronize()
        try await store.saveGarment(id: id, fields: fields)
        await remote.change(id: id, deleted: true)
        try await store.synchronize()
        let deleted = await store.status()
        XCTAssertTrue(deleted.garments.first?.deleted == true)
        do { try await store.resolveGarment(id: id, keepLocal: true); XCTFail("Cannot revive") }
        catch { XCTAssertEqual(error as? OfflineError, .conflict) }
        try await store.resolveGarment(id: id, keepLocal: false)
        let accepted = await store.status()
        XCTAssertTrue(accepted.outbox.isEmpty)
    }

    func testDeletedAccountClearsPendingWritesAndPersistsFence() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SyncTestRemote()
        let account = remote.accountID
        let store = try OfflineStore(accountID: account, database: db, remote: remote)
        try await store.saveGarment(fields: fields)
        await remote.deleteAccount()
        do { try await store.synchronize(); XCTFail("Expected account fence") } catch is APIv1.Failure {}
        let restored = try OfflineStore(accountID: account, database: db, remote: remote)
        let state = await restored.status()
        XCTAssertTrue(state.deleted)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertTrue(state.garments.isEmpty)
        do { try await restored.saveGarment(fields: fields); XCTFail("Deleted store cannot write") }
        catch { XCTAssertEqual(error as? OfflineError, .accountDeleted) }
        let counts = await remote.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testDeletionDuringInflightSaveCannotRepopulateDatabase() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let remote = SuspendedSyncRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        try await store.saveGarment(fields: fields)
        let sync = Task { try await store.synchronize() }
        await remote.waitUntilSaving()
        try await store.invalidateAccount()
        await remote.finish()
        do { try await sync.value; XCTFail("Deleted store must discard response") }
        catch { XCTAssertEqual(error as? OfflineError, .accountDeleted) }
        let restored = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        let state = await restored.status()
        XCTAssertTrue(state.deleted)
        XCTAssertTrue(state.garments.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testFailedLocalTransactionDoesNotPublishAnUnpersistedEdit() async throws {
        let db = database()
        let directory = db.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = SyncTestRemote()
        let store = try OfflineStore(accountID: remote.accountID, database: db, remote: remote)
        // Replace the parent directory with a file to force a real filesystem failure.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        do { try await store.saveGarment(fields: fields); XCTFail("Expected storage failure") }
        catch { /* The exact Cocoa/SQLite error depends on the filesystem. */ }
        let state = await store.status()
        XCTAssertTrue(state.garments.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
    }

    func testFutureAndForeignGarmentsCannotEnterLocalWearHistory() async throws {
        let db = database()
        defer { try? FileManager.default.removeItem(at: db.url.deletingLastPathComponent()) }
        let store = try OfflineStore(accountID: UUID(), database: db, remote: SyncTestRemote())
        let id = try await store.saveGarment(fields: fields)
        for (day, ids) in [("2999-01-01", [id]), ("2026-01-01", [UUID()]), ("2026-01-01", [id, id])] {
            do { try await store.recordWear(wornOn: day, timezone: "Europe/Warsaw", garmentIDs: ids); XCTFail("Invalid wear") }
            catch { XCTAssertEqual(error as? APIClientError, .invalidRequest) }
        }
        let state = await store.status()
        XCTAssertTrue(state.wears.isEmpty)
    }
}

private actor SyncTestRemote: OfflineRemote {
    nonisolated let accountID = UUID()
    private var garments: [SyncGarment] = []
    private var wears: [SyncWear] = []
    private var replay: [UUID: APIv1.GarmentDTO] = [:]
    private var timeout = false
    private var wearReplay: [UUID: SyncWear] = [:]
    private(set) var wearRequests: [Data] = []
    private(set) var initialRequests: [Data] = []
    private var initialReplay: [UUID: SyncGarment] = [:]
    private var wearTimeout = false
    private var deleted = false
    private(set) var requests: [Data] = []
    func timeoutNextWrite() { timeout = true }
    func timeoutNextWear() { wearTimeout = true }
    func deleteAccount() { deleted = true }
    func counts() -> [Int] { [garments.count, wears.count] }
    func snapshot() throws -> SyncSnapshot {
        if deleted { throw failure("account_unavailable") }
        return SyncSnapshot(accountID: accountID, garments: garments, wears: wears)
    }
    func change(id: UUID, deleted: Bool) {
        let old = garments.first { $0.id == id }!
        garments.removeAll { $0.id == id }
        garments.append(SyncGarment(id: id, version: old.version + 1, deleted: deleted, fields: old.fields))
    }
    func save(_ operation: APIv1.SaveGarment) throws -> APIv1.GarmentDTO {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        requests.append(try encoder.encode(operation))
        if let dto = replay[operation.operationID] { return dto }
        let old = garments.first { $0.id == operation.garmentID }
        guard old?.version == operation.baseVersion else { throw failure("version_conflict") }
        let dto = APIv1.GarmentDTO(id: operation.garmentID, version: (old?.version ?? 0) + 1, name: operation.garment.name,
            category: operation.garment.category, priceGrosz: operation.garment.priceGrosz, availability: operation.garment.availability, archived: operation.garment.archived)
        replay[operation.operationID] = dto
        garments.removeAll { $0.id == dto.id }
        garments.append(SyncGarment(id: dto.id, version: dto.version, deleted: false, fields: operation.garment))
        if timeout { timeout = false; throw URLError(.timedOut) }
        return dto
    }
    func initialHistory(_ operation: SaveInitialHistory) throws -> SyncGarment {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        initialRequests.append(try encoder.encode(operation))
        if let saved = initialReplay[operation.operationID] { return saved }
        guard let old = garments.first(where: { $0.id == operation.id }), !old.deleted,
              old.version == operation.baseVersion else { throw failure("version_conflict") }
        var metadata = old.display
        metadata.initialWearHistory = operation.history
        let saved = SyncGarment(id: old.id, version: old.version + 1, deleted: false, fields: old.fields, metadata: metadata)
        garments.removeAll { $0.id == old.id }
        garments.append(saved)
        initialReplay[operation.operationID] = saved
        if timeout { timeout = false; throw URLError(.timedOut) }
        return saved
    }
    func changeWear(id: UUID, deleted: Bool) {
        let old = wears.first { $0.id == id }!
        wears.removeAll { $0.id == id }
        wears.append(SyncWear(id: id, version: old.version + 1, deleted: deleted,
            wornOn: old.wornOn, timezone: old.timezone, garmentIDs: old.garmentIDs))
    }
    func save(_ operation: SaveWear) throws -> SyncWear {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        wearRequests.append(try encoder.encode(operation))
        if let existing = wearReplay[operation.operationID] { return existing }
        let input = operation.wear
        let old = wears.first { $0.id == input.id }
        guard (old?.version ?? 0) == input.version, old?.deleted != true else { throw failure("version_conflict") }
        let wear = SyncWear(id: input.id, version: input.version + 1, deleted: false, wornOn: input.wornOn, timezone: input.timezone, garmentIDs: input.garmentIDs)
        wears.removeAll { $0.id == wear.id }
        wears.append(wear)
        wearReplay[operation.operationID] = wear
        if wearTimeout { wearTimeout = false; throw URLError(.timedOut) }
        return wear
    }
    private func failure(_ code: String) -> APIv1.Failure {
        APIv1.Failure(code: code, message: "Test", requestID: UUID())
    }
}

private actor SuspendedSyncRemote: OfflineRemote {
    nonisolated let accountID = UUID()
    private var pending: CheckedContinuation<APIv1.GarmentDTO, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var operation: APIv1.SaveGarment?
    func snapshot() -> SyncSnapshot { SyncSnapshot(accountID: accountID, garments: [], wears: []) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO {
        self.operation = operation
        return await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func save(_ operation: SaveWear) throws -> SyncWear { throw OfflineError.invalidState }
    func waitUntilSaving() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        guard let operation else { return }
        pending?.resume(returning: APIv1.GarmentDTO(id: operation.garmentID, version: 1,
            name: operation.garment.name, category: operation.garment.category,
            priceGrosz: operation.garment.priceGrosz, availability: operation.garment.availability, archived: operation.garment.archived))
        pending = nil
    }
}
