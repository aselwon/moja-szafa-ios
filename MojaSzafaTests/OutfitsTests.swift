import XCTest
@testable import MojaSzafa

@MainActor
final class OutfitsTests: XCTestCase {
    func testValidationAndMembershipAreIndependentFromWearSnapshot() {
        let garment = Garment(id: UUID(), name: "Shirt", archived: true)
        var outfit = Outfit(name: "Work", garments: [garment])
        let wear = SyncWear(id: UUID(), version: 1, deleted: false, wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: outfit.garments.map(\.id))
        XCTAssertTrue(outfit.isValid)
        XCTAssertTrue(outfit.garments[0].archived)
        outfit.garments = [Garment(id: UUID(), name: "Dress")]
        XCTAssertEqual(wear.garmentIDs, [garment.id])
        outfit.name = " \n "
        XCTAssertFalse(outfit.isValid)
        outfit.name = "Work"
        outfit.garments = []
        XCTAssertFalse(outfit.isValid)
        outfit.garments = [garment, garment]
        XCTAssertFalse(outfit.isValid)
    }

    func testConflictKeepsExistingListAndAllowsReload() async {
        let outfit = Outfit(version: 3, name: "Server", garments: [Garment(id: UUID(), name: "Dress")])
        let model = OutfitsModel(repository: ConflictingOutfitFixture(outfit: outfit))
        await model.load()
        var edited = outfit
        edited.name = "Local"
        let saved = await model.save(edited)
        XCTAssertFalse(saved)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.errorKey, "outfits.conflict")
        XCTAssertEqual(model.items, [outfit])
        await model.load()
        XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.items, [outfit])
    }

    func testTimeoutRetryUsesSameIntentThenUpdatesExistingOutfit() async {
        let repository = OutfitFixture()
        let model = OutfitsModel(repository: repository)
        var outfit = Outfit(name: "Work", garments: [Garment(id: UUID(), name: "Shirt")])
        let first = await model.save(outfit)
        XCTAssertFalse(first)
        XCTAssertNotNil(model.pending)
        let second = await model.save(outfit)
        XCTAssertTrue(second)
        XCTAssertNil(model.pending)
        let requests = await repository.requests
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(model.items.count, 1)
        outfit = model.items[0]
        outfit.name = "Weekend"; outfit.favorite = true
        let edited = await model.save(outfit)
        XCTAssertTrue(edited)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].name, "Weekend")
        XCTAssertTrue(model.items[0].favorite)
        let updatedRequests = await repository.requests
        XCTAssertNotEqual(updatedRequests[1].operationID, updatedRequests[2].operationID)
        XCTAssertEqual(updatedRequests[2].baseVersion, 1)
    }
}

private actor OutfitFixture: OutfitRepository {
    var requests: [SaveOutfit] = []
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: [], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        requests.append(request)
        if requests.count == 1 { throw URLError(.timedOut) }
        return Outfit(id: request.id, version: request.baseVersion + 1, name: request.name,
                      favorite: request.favorite, garments: request.garmentIDs.map { Garment(id: $0, name: "Shirt") })
    }
}

private struct ConflictingOutfitFixture: OutfitRepository {
    let outfit: Outfit
    func outfits(cursor: UUID?) async throws -> OutfitPage { OutfitPage(items: [outfit], nextCursor: nil) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        throw APIv1.Failure(code: "version_conflict", message: "Changed", requestID: UUID())
    }
}

@MainActor
final class SuggestionsTests: XCTestCase {
    func testManualReplacementPreservesOtherSlotsAndWorksAfterAIFailure() async {
        let top = Garment(id: UUID(), name: "Top", category: .top)
        let bottom = Garment(id: UUID(), name: "Bottom", category: .bottom)
        let shoes = Garment(id: UUID(), name: "Shoes", category: .shoes)
        let replacement = Garment(id: UUID(), name: "Other top", category: .top)
        let source = SuggestionFixture(ids: [top.id, bottom.id, shoes.id])
        let model = SuggestionsModel(source: source, wardrobe: SuggestionWardrobe(items: [top, bottom, shoes, replacement]),
                                     outfits: OutfitFixture(), offline: nil)
        await model.load()
        XCTAssertTrue(model.items[0].missing.isEmpty)
        let id = model.items[0].id
        await source.fail()
        await model.load()
        XCTAssertNotNil(model.errorKey)
        XCTAssertEqual(model.items.count, 1)
        await model.replace(suggestionID: id, garmentID: top.id, with: replacement)
        XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.items[0].outfit.garments.map(\.id), [replacement.id, bottom.id, shoes.id])
        XCTAssertTrue(model.items[0].edited)
        XCTAssertFalse(model.items[0].worn)
        await model.replace(suggestionID: id, garmentID: replacement.id, with: shoes)
        XCTAssertNotNil(model.errorKey)
        XCTAssertEqual(model.items[0].outfit.garments.map(\.id), [replacement.id, bottom.id, shoes.id])
    }

    func testUnknownAndUnavailableIDsFailClosed() async {
        let garment = Garment(id: UUID(), name: "Laundry", availability: .laundry)
        for ids in [[UUID()], [garment.id], [garment.id, garment.id]] {
            let model = SuggestionsModel(source: SuggestionFixture(ids: ids), wardrobe: SuggestionWardrobe(items: [garment]),
                                         outfits: OutfitFixture(), offline: nil)
            await model.load()
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertNotNil(model.errorKey)
        }
    }

    func testPendingSaveLocksReplacementAndRetriesSamePayload() async {
        let top = Garment(id: UUID(), name: "Top", category: .top)
        let replacement = Garment(id: UUID(), name: "Dress", category: .dress)
        let outfits = OutfitFixture()
        let model = SuggestionsModel(source: SuggestionFixture(ids: [top.id]),
                                     wardrobe: SuggestionWardrobe(items: [top, replacement]), outfits: outfits, offline: nil)
        await model.load()
        XCTAssertEqual(model.items[0].missing, [.bottom, .shoes])
        let id = model.items[0].id
        await model.save(id)
        XCTAssertNotNil(model.saves.pending)
        await model.replace(suggestionID: id, garmentID: top.id, with: replacement)
        XCTAssertEqual(model.items[0].outfit.garments, [top])
        await model.save(id)
        let requests = await outfits.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertNil(model.saves.pending)
        XCTAssertFalse(model.items[0].worn)
    }
}

private actor SuggestionFixture: SuggestionRepository {
    let ids: [UUID]
    var failing = false
    init(ids: [UUID]) { self.ids = ids }
    func fail() { failing = true }
    func latestSuggestions() async throws -> SuggestionResult? {
        if failing { throw URLError(.notConnectedToInternet) }
        return SuggestionResult(outfits: [.init(garment_ids: ids, rationale: "For work")], shortfall_reason: nil)
    }
}
private struct SuggestionWardrobe: WardrobeRepository {
    let items: [Garment]
    func garments() async throws -> [Garment] { items }
}

extension SuggestionsTests {
    func testWearIsExplicitLocalDaySnapshotAndSurvivesRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = OfflineDatabase(url: directory.appendingPathComponent("state.sqlite"))
        let account = UUID()
        let store = try OfflineStore(accountID: account, database: database, remote: SuggestionsOfflineRemote())
        let id = try await store.saveGarment(fields: .init(name: "Dress", category: .dress, priceGrosz: nil, availability: .available))
        let model = SuggestionsModel(source: SuggestionFixture(ids: [id]), wardrobe: store, outfits: OutfitFixture(), offline: store)
        await model.load()
        let before = await store.status()
        XCTAssertTrue(before.wears.isEmpty)
        let suggestionID = try XCTUnwrap(model.items.first?.id)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Warsaw"))
        await model.wear(suggestionID, now: date, timezone: zone)
        await model.wear(suggestionID, now: date, timezone: zone)
        XCTAssertNil(model.errorKey)
        let restored = try OfflineStore(accountID: account, database: database, remote: SuggestionsOfflineRemote())
        let state = await restored.status()
        XCTAssertEqual(state.wears.count, 1)
        XCTAssertEqual(state.wears.first?.garmentIDs, [id])
        XCTAssertEqual(state.wears.first?.wornOn, "2026-01-02")
        XCTAssertEqual(state.wears.first?.timezone, "Europe/Warsaw")
    }
}

private struct SuggestionsOfflineRemote: OfflineRemote {
    func snapshot() async throws -> SyncSnapshot { throw URLError(.notConnectedToInternet) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO { throw URLError(.notConnectedToInternet) }
    func save(_ operation: SaveWear) async throws -> SyncWear { throw URLError(.notConnectedToInternet) }
}
