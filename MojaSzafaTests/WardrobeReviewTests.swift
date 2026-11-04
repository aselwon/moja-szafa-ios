import XCTest
@testable import MojaSzafa

@MainActor
final class WardrobeReviewTests: XCTestCase {
    func testKeepSurvivesRelaunchAndDoesNotChangeGarments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("kept.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = ReviewFixture()
        let first = WardrobeReviewModel(repository: repository, journalURL: url)
        await first.load()
        let id = try XCTUnwrap(first.snapshot?.garments.first?.id)
        XCTAssertTrue(first.keep(id))
        let restored = WardrobeReviewModel(repository: repository, journalURL: url)
        XCTAssertTrue(restored.kept.contains(id))
        XCTAssertTrue(restored.keep(id, value: false))
        XCTAssertTrue(restored.kept.isEmpty)
        let writes = await repository.archivedIDs
        XCTAssertTrue(writes.isEmpty)
    }
    func testArchiveRefreshesListAndFailedArchiveDoesNotPretendSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = ReviewFixture()
        let model = WardrobeReviewModel(repository: repository, journalURL: url)
        await model.load()
        let garment = try XCTUnwrap(model.snapshot?.garments.first)
        await model.archive(garment)
        XCTAssertTrue(model.snapshot?.garments.first?.archived == true)
        XCTAssertTrue(model.candidates().isEmpty)
        await repository.failArchive()
        await model.archive(garment)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.errorKey,"review.archiveFailed")
    }
    func testCorruptChoicesRequireExplicitReset() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        let model = WardrobeReviewModel(repository: ReviewFixture(), journalURL: url)
        XCTAssertTrue(model.journalFailed)
        XCTAssertFalse(model.keep(UUID()))
        model.resetKept()
        XCTAssertFalse(model.journalFailed)
        XCTAssertTrue(model.keep(UUID()))
    }
    func testSavedOutfitSearchReadsLaterPagesWithoutRecordingWear() async throws {
        let garment = Garment(id:UUID(),name:"Shirt")
        let match = Outfit(name:"Matching",garments:[garment])
        let repository = ReviewOutfitFixture(match: match)
        let model = ReviewOutfitsModel(repository: repository)
        await model.load(garmentID:garment.id)
        XCTAssertEqual(model.items.map(\.id),[match.id])
        let reads = await repository.reads
        XCTAssertEqual(reads,2)
        XCTAssertNil(model.errorKey)
    }
    func testRecentEstimateIsNotFalselyClassifiedAsRare() async {
        let repository = ReviewFixture()
        await repository.addRecentEstimate()
        let model = WardrobeReviewModel(repository:repository,journalURL:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await model.load()
        let now = ISO8601DateFormatter().date(from:"2026-11-05T12:00:00Z")!
        XCTAssertEqual(model.candidates(now:now,timezone:.gmt).count,1)
    }
}
private actor ReviewFixture: WardrobeRepository {
    var items = [Garment(id:UUID(),name:"Shirt",availability:.laundry)]
    var archivedIDs: [UUID] = []
    private var failing = false
    func failArchive() { failing = true }
    func addRecentEstimate() { items.append(Garment(id:UUID(),name:"Estimated",initialWearHistory:InitialWearHistory(count:10,startDate:"2026-11-01"))) }
    func garments() async throws -> [Garment] { items }
    func statisticsSnapshot() async throws -> StatisticsSnapshot { StatisticsSnapshot(garments:items,wears:[]) }
    func setArchived(id: UUID, archived: Bool) async throws -> GarmentDetail {
        if failing { throw URLError(.notConnectedToInternet) }
        let index = items.firstIndex { $0.id == id }!
        items[index].archived = archived; archivedIDs.append(id)
        return GarmentDetail(garment:items[index],wornOn:[])
    }
}
private actor ReviewOutfitFixture: OutfitRepository {
    let match: Outfit
    let cursor = UUID()
    var reads = 0
    init(match: Outfit) { self.match = match }
    func outfits(cursor: UUID?) async throws -> OutfitPage {
        reads += 1
        if cursor == nil { return OutfitPage(items:[],nextCursor:self.cursor) }
        return OutfitPage(items:[match],nextCursor:nil)
    }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit { XCTFail("Reading outfits must not write"); throw RepositoryError.backendNotConfigured }
}
