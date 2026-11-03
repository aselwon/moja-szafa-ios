import XCTest
@testable import MojaSzafa

@MainActor
final class OutfitsTests: XCTestCase {
    func testValidationAndWireFormat() throws {
        var draft = Outfit()
        XCTAssertThrowsError(try draft.validate())
        draft.name = "  Work  "; draft.garmentIDs = [UUID()]
        try draft.validate()
        let data = try JSONEncoder().encode(SaveOutfit(operationID: UUID(), outfit: draft))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["base_version"] is NSNull)
        XCTAssertEqual((json["outfit"] as? [String: Any])?["name"] as? String, "Work")
        draft.garmentIDs.append(draft.garmentIDs[0])
        XCTAssertThrowsError(try draft.validate())
        draft.garmentIDs = [UUID()]; draft.name = String(repeating: "x", count: 201)
        XCTAssertThrowsError(try draft.validate())
    }

    func testTimeoutRetryReusesIntentAndEditReplacesExistingOutfit() async throws {
        let fixture = OutfitFixture()
        let model = OutfitsModel(repository: fixture, wardrobe: fixture)
        await model.load()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.garments.count, 2)
        XCTAssertTrue(model.garments.contains { $0.archived })
        var draft = Outfit(name: "Work", garmentIDs: [OutfitFixture.firstID])
        let first = await model.save(draft)
        XCTAssertFalse(first)
        let pendingID = try XCTUnwrap(model.pending?.operationID)
        let retry = await model.save(draft)
        XCTAssertTrue(retry)
        XCTAssertNil(model.pending)
        let calls = await fixture.calls
        XCTAssertEqual(calls.map(\.operationID), [pendingID, pendingID])
        XCTAssertEqual(model.outfits.count, 1)
        draft = try XCTUnwrap(model.outfits.first)
        draft.name = "Weekend"; draft.favorite = true; draft.garmentIDs = [OutfitFixture.secondID]
        let edited = await model.save(draft)
        XCTAssertTrue(edited)
        XCTAssertEqual(model.outfits.count, 1)
        XCTAssertEqual(model.outfits.first?.version, 2)
        XCTAssertEqual(model.outfits.first?.garmentIDs, [OutfitFixture.secondID])
        XCTAssertEqual(model.outfits.first?.favorite, true)
    }

    func testUnknownGarmentCannotBeSubmitted() async {
        let fixture = OutfitFixture()
        let model = OutfitsModel(repository: fixture, wardrobe: fixture)
        await model.load()
        let result = await model.save(Outfit(name: "Unknown", garmentIDs: [UUID()]))
        XCTAssertFalse(result)
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private actor OutfitFixture: OutfitRepository, WardrobeRepository {
    static let firstID = UUID()
    static let secondID = UUID()
    var calls: [SaveOutfit] = []
    func outfits() async throws -> [Outfit] { [] }
    func garments() async throws -> [Garment] {
        [Garment(id: Self.firstID, name: "Shirt"), Garment(id: Self.secondID, name: "Archived", archived: true)]
    }
    func saveOutfit(_ operation: SaveOutfit) async throws -> Outfit {
        calls.append(operation)
        if calls.count == 1 { throw URLError(.timedOut) }
        var saved = operation.outfit; saved.version += 1
        return saved
    }
}
