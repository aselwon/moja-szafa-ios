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
