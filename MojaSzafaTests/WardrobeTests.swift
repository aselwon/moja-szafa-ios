import XCTest
@testable import MojaSzafa

@MainActor
final class WardrobeTests: XCTestCase {
    func testCostPerWearUsesUniqueHistoricalDaysAndRendersOnlyAtBoundary() {
        let days = (1...100).map { "day-\($0)" }
        XCTAssertEqual(CostPerWear(priceGrosz: 80000, wornOn: days + days).roundedGrosz, 800)
        XCTAssertEqual(CostPerWear(priceGrosz: 0, wornOn: ["2026-01-01"]).roundedGrosz, 0)
        XCTAssertNil(CostPerWear(priceGrosz: nil, wornOn: days).roundedGrosz)
        XCTAssertNil(CostPerWear(priceGrosz: 0, wornOn: []).roundedGrosz)
        let ratio = CostPerWear(priceGrosz: 100, wornOn: ["a", "b", "c"])
        XCTAssertEqual(ratio.priceGrosz, 100)
        XCTAssertEqual(ratio.wearDays, 3)
        XCTAssertEqual(ratio.roundedGrosz, 33)
        XCTAssertEqual(CostPerWear(priceGrosz: 1, wornOn: ["a", "b"]).roundedGrosz, 1)
        XCTAssertEqual(CostPerWear(priceGrosz: Int64.max, wornOn: ["a"]).roundedGrosz, Int64.max)
        XCTAssertEqual(CostPerWear(priceGrosz: Int64.max, wornOn: ["a", "b"]).roundedGrosz, 4611686018427387904)
    }

    func testCostPerWearRecomputesAfterPriceEditAndUndoWithoutMutatingHistory() {
        var garment = Garment(id: UUID(), name: "Shirt", priceGrosz: 900)
        let history = ["2026-01-01", "2026-01-01", "2026-01-02"]
        let before = GarmentDetail(garment: garment, wornOn: history)
        XCTAssertEqual(before.costPerWear.roundedGrosz, 450)
        garment.priceGrosz = 1200
        let edited = GarmentDetail(garment: garment, wornOn: history)
        XCTAssertEqual(edited.costPerWear.roundedGrosz, 600)
        XCTAssertEqual(edited.wornOn, before.wornOn)
        let afterUndo = GarmentDetail(garment: garment, wornOn: ["2026-01-01"])
        XCTAssertEqual(afterUndo.costPerWear.roundedGrosz, 1200)
    }

    func testThousandItemsLoadOnlyOnePageThenAppendWithoutFetchingImages() async {
        let repository = BrowseFixture()
        let model = WardrobeModel(repository: repository)
        await model.load()
        XCTAssertEqual(model.items.count, 40)
        XCTAssertEqual(model.nextOffset, 40)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 80)
        let calls = await repository.offsets
        XCTAssertEqual(calls, [0, 40])
        let images = await repository.imageCalls
        XCTAssertEqual(images, 0)
    }

    func testLateResponseCannotReplaceNewSearch() async {
        let repository = DelayedBrowseFixture()
        let model = WardrobeModel(repository: repository)
        let first = Task { await model.reload() }
        await repository.waitForRequest()
        model.query.search = "new"
        await model.reload()
        await repository.finishOldRequest()
        await first.value
        XCTAssertEqual(model.items.map(\.name), ["new"])
    }

    func testReadModelDecodesNullablePriceAndImageWithoutOriginalURLs() throws {
        let data = Data(#"{"items":[{"id":"00000000-0000-0000-0000-000000000001","name":"Shirt","category":"top","availability":"available","priceGrosz":null,"imageID":"00000000-0000-0000-0000-000000000002","brand":null,"colors":["blue"],"seasons":["winter"],"archived":false}],"nextOffset":null,"cached":false}"#.utf8)
        let page = try JSONDecoder().decode(WardrobePage.self, from: data)
        XCTAssertEqual(page.items.first?.category, .top)
        XCTAssertNil(page.items.first?.priceGrosz)
        XCTAssertNotNil(page.items.first?.imageID)
    }

    func testQueryAppliesBeforePaginationAndUnknownPriceSortsLast() {
        let items = [
            Garment(id: UUID(), name: "Blue shirt", category: .top, priceGrosz: nil),
            Garment(id: UUID(), name: "Blue shoes", category: .shoes, priceGrosz: 0),
            Garment(id: UUID(), name: "Blue top", category: .top, priceGrosz: 0),
            Garment(id: UUID(), name: "Red top", category: .top, priceGrosz: 100)
        ]
        var query = WardrobeQuery(search: "blue", category: .top, sort: .price)
        let page = query.page(items, offset: 0, limit: 1, cached: false)
        XCTAssertEqual(page.items.map(\.name), ["Blue top"])
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertEqual(query.page(items, offset: 1, limit: 1, cached: false).items.first?.name, "Blue shirt")
        query.availability = .laundry
        XCTAssertTrue(query.page(items, offset: 0, limit: 40, cached: false).items.isEmpty)
        query = WardrobeQuery(search: "%")
        XCTAssertTrue(query.page(items, offset: 0, limit: 40, cached: false).items.isEmpty)
    }

    func testFailedNextPagePreservesItemsAndRetryOffset() async {
        let repository = BrowseFixture()
        let model = WardrobeModel(repository: repository)
        await model.load()
        await repository.failNext()
        await model.loadMore()
        XCTAssertTrue(model.pageFailed)
        XCTAssertTrue(model.pageOffline)
        XCTAssertEqual(model.items.count, 40)
        XCTAssertEqual(model.nextOffset, 40)
        await model.loadMore()
        XCTAssertFalse(model.pageFailed)
        XCTAssertEqual(model.items.count, 80)
        model.query.search = "Item 999"
        await model.reload()
        XCTAssertEqual(model.items.map(\.name), ["Item 999"])
        XCTAssertNil(model.nextOffset)
    }

    func testOfflineSnapshotShowsDistinctHistoricalDaysAndKnownZeroPrice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try OfflineStore(accountID: UUID(), database: OfflineDatabase(url: directory.appendingPathComponent("state.sqlite")), remote: UnreachableRemote())
        let id = try await store.saveGarment(fields: APIv1.GarmentFields(name: "Shirt", category: .top, priceGrosz: 0, availability: .laundry))
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [id])
        try await store.recordWear(wornOn: "2026-01-01", timezone: "America/New_York", garmentIDs: [id])
        let page = try await store.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertTrue(page.cached)
        XCTAssertEqual(page.items.first?.availability, .laundry)
        let detail = try await store.detail(id: id)
        XCTAssertTrue(detail.cached)
        XCTAssertEqual(detail.wornOn, ["2026-01-01"])
        XCTAssertEqual(detail.garment.priceGrosz, 0)
    }

    func testDurableDisplayMetadataKeepsArchivedItemsOutOfActiveWardrobe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = OfflineDatabase(url: directory.appendingPathComponent("state.sqlite"))
        let accountID = UUID()
        let id = UUID()
        var state = OfflineStore.State(accountID: accountID)
        state.garments = [SyncGarment(id: id, version: 1, deleted: false,
            fields: APIv1.GarmentFields(name: "Archived", category: .top, priceGrosz: nil, availability: .available),
            metadata: Garment(id: id, name: "Archived", brand: "Brand", archived: true))]
        try database.write(JSONEncoder().encode(state))
        let store = try OfflineStore(accountID: accountID, database: database, remote: UnreachableRemote())
        let active = try await store.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertTrue(active.items.isEmpty)
        let archived = try await store.page(query: WardrobeQuery(search: "Brand", archived: true), offset: 0, limit: 40)
        XCTAssertEqual(archived.items.map(\.id), [id])
    }

    func testAPIPageCachesOnlyMetadataForOfflineAndRejectsCrossOriginImageLink() async throws {
        let transport = BrowseTransport()
        let client = try APIClient(baseURL: URL(string: "https://example.invalid")!, transport: transport) { "test-session" }
        let repository = APIWardrobeRepository(client: client)
        let online = try await repository.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertFalse(online.cached)
        await transport.goOffline()
        let offline = try await repository.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertTrue(offline.cached)
        do {
            _ = try await repository.page(query: WardrobeQuery(search: "different"), offset: 0, limit: 40)
            XCTFail("Uncached queries must not return misleading empty results")
        } catch is URLError {}
        await transport.imageMode()
        do {
            _ = try await client.wardrobeThumbnail(imageID: UUID())
            XCTFail("Must reject a foreign signed URL")
        } catch APIClientError.invalidResponse {}
        let count = await transport.requests.count
        XCTAssertEqual(count, 4) // No GET to the foreign origin.
    }
}

private actor BrowseFixture: WardrobeRepository {
    private(set) var offsets: [Int] = []
    private(set) var imageCalls = 0
    private var fail = false
    private let items = (0..<1000).map { Garment(id: UUID(), name: "Item \($0)") }
    func garments() async throws -> [Garment] { XCTFail("Must use the page contract"); return [] }
    func failNext() { fail = true }
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        offsets.append(offset)
        if fail { fail = false; throw URLError(.notConnectedToInternet) }
        return query.page(items, offset: offset, limit: limit, cached: false)
    }
    func thumbnail(imageID: UUID) async throws -> Data { imageCalls += 1; return Data() }
}

private struct UnreachableRemote: OfflineRemote {
    func snapshot() async throws -> SyncSnapshot { throw URLError(.notConnectedToInternet) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO { throw URLError(.notConnectedToInternet) }
    func save(_ operation: SaveWear) async throws -> SyncWear { throw URLError(.notConnectedToInternet) }
}

private actor BrowseTransport: APITransport {
    private var mode = 0
    private(set) var requests: [URLRequest] = []
    func goOffline() { mode = 1 }
    func imageMode() { mode = 2 }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if mode == 1 { throw URLError(.notConnectedToInternet) }
        let body = mode == 2 ? #"{"url":"https://foreign.invalid/image"}"# :
            #"{"data":{"items":[],"nextOffset":null,"cached":false},"request_id":"00000000-0000-0000-0000-000000000001"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor DelayedBrowseFixture: WardrobeRepository {
    private var pending: CheckedContinuation<WardrobePage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func garments() async throws -> [Garment] { [] }
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        if query.search == "new" {
            return WardrobePage(items: [Garment(id: UUID(), name: "new")], nextOffset: nil)
        }
        return await withCheckedContinuation {
            pending = $0
            started?.resume(); started = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishOldRequest() {
        pending?.resume(returning: WardrobePage(items: [Garment(id: UUID(), name: "old")], nextOffset: nil))
        pending = nil
    }
}
