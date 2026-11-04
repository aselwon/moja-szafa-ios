import XCTest
@testable import MojaSzafa

final class StatisticsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
    private func wear(_ ids: [UUID], _ day: String, deleted: Bool = false) -> SyncWear {
        SyncWear(id: UUID(), version: 1, deleted: deleted, wornOn: day, timezone: "Pacific/Kiritimati", garmentIDs: ids)
    }
    func testDateFilterChangesActivityButNotLifetimeCostOrValue() {
        let garment = Garment(id: UUID(), name: "Shirt", priceGrosz: 1200)
        let snapshot = StatisticsSnapshot(garments: [garment], wears: [wear([garment.id],"2026-01-01"),wear([garment.id],"2026-11-01"),wear([garment.id],"2026-11-01")])
        let all = WardrobeStatistics(snapshot: snapshot, period: .all, includeArchived: false, now: now, timezone: .gmt)
        let month = WardrobeStatistics(snapshot: snapshot, period: .month, includeArchived: false, now: now, timezone: .gmt)
        XCTAssertEqual(all.mostWorn.first?.activityDays,2)
        XCTAssertEqual(month.mostWorn.first?.activityDays,1)
        XCTAssertEqual(month.rows.first?.cost,all.rows.first?.cost)
        XCTAssertEqual(month.rows.first?.cost.roundedGrosz,600)
        XCTAssertEqual(month.knownValueGrosz,all.knownValueGrosz)
    }
    func testUnknownPriceZeroAndHugeKnownPricesRemainDistinct() {
        let unknown = Garment(id: UUID(), name: "Unknown")
        let free = Garment(id: UUID(), name: "Gift", priceGrosz: 0)
        let large = Garment(id: UUID(), name: "Large", priceGrosz: Int64.max)
        let another = Garment(id: UUID(), name: "Another", priceGrosz: Int64.max)
        let stats = WardrobeStatistics(snapshot: StatisticsSnapshot(garments:[unknown,free,large,another],wears:[wear([free.id,large.id],"2026-11-01")]),period:.all,includeArchived:false,now:now,timezone:.gmt)
        XCTAssertEqual(stats.missingPrices,1)
        XCTAssertEqual(stats.knownValueGrosz,Decimal(Int64.max)*2)
        XCTAssertEqual(stats.costRanking.map(\.id),[free.id,large.id])
        XCTAssertEqual(Set(stats.neverWorn.map(\.id)),Set([unknown.id,another.id]))
    }
    func testInactivityDoesNotInventDatesForNewOrEstimatedHistory() {
        let old = Garment(id:UUID(),name:"Old")
        let new = Garment(id:UUID(),name:"New")
        let uncertain = Garment(id:UUID(),name:"Estimated",initialWearHistory:InitialWearHistory(count:10,startDate:"2026-11-01"))
        let proven = Garment(id:UUID(),name:"Old estimate",initialWearHistory:InitialWearHistory(count:10,startDate:"2026-01-01"))
        let stats = WardrobeStatistics(snapshot:StatisticsSnapshot(garments:[old,new,uncertain,proven],wears:[wear([old.id],"2026-01-01")]),period:.month,includeArchived:false,now:now,timezone:.gmt)
        XCTAssertEqual(Set(stats.unused90.map(\.id)),Set([old.id,proven.id]))
        XCTAssertEqual(stats.neverWorn.map(\.id),[new.id])
        XCTAssertTrue(stats.mostWorn.isEmpty)
    }
    func testDeletedEventsArchivedItemsAndEstimateBoundary() {
        let item = Garment(id:UUID(),name:"Estimate",priceGrosz:1200,initialWearHistory:InitialWearHistory(count:10,startDate:"2026-01-02"))
        let archived = Garment(id:UUID(),name:"Archived",priceGrosz:100,archived:true)
        let source = StatisticsSnapshot(garments:[item,archived],wears:[wear([item.id],"2026-01-01"),wear([item.id],"2026-01-02"),wear([item.id],"2026-11-01",deleted:true)])
        let stats = WardrobeStatistics(snapshot:source,period:.all,includeArchived:false,now:now,timezone:.gmt)
        XCTAssertEqual(stats.rows.count,1)
        XCTAssertEqual(stats.rows[0].cost.wearDays,11)
        XCTAssertEqual(stats.rows[0].activityDays,2)
        XCTAssertTrue(stats.rows[0].cost.isEstimated)
        XCTAssertEqual(WardrobeStatistics(snapshot:source,period:.all,includeArchived:true,now:now,timezone:.gmt).knownValueGrosz,1300)
    }
    func testCostRankingUsesUnroundedRatios() {
        let a = Garment(id:UUID(),name:"A",priceGrosz:1)
        let b = Garment(id:UUID(),name:"B",priceGrosz:1)
        let stats = WardrobeStatistics(snapshot:StatisticsSnapshot(garments:[a,b],wears:[wear([a.id,b.id],"2026-11-01"),wear([a.id,b.id],"2026-11-02"),wear([b.id],"2026-11-03")]),period:.all,includeArchived:false,now:now,timezone:.gmt)
        XCTAssertEqual(stats.costRanking.map(\.id),[b.id,a.id])
    }
}


@MainActor
final class StatisticsModelTests: XCTestCase {
    func testFailedRefreshDoesNotRetainPriorAccountStatistics() async {
        let repository = StatisticsFixture()
        let model = StatisticsModel(repository: repository)
        await model.load()
        XCTAssertNotNil(model.snapshot)
        await repository.revoke()
        await model.load()
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.errorKey)
    }
}
private actor StatisticsFixture: WardrobeRepository {
    private var revoked = false
    func revoke() { revoked = true }
    func garments() async throws -> [Garment] { [] }
    func statisticsSnapshot() async throws -> StatisticsSnapshot {
        if revoked { throw OfflineError.accountDeleted }
        return StatisticsSnapshot(garments: [Garment(id: UUID(), name: "Private")], wears: [])
    }
}
