import Combine
import Foundation

struct StatisticsSnapshot: Sendable {
    let garments: [Garment]
    let wears: [SyncWear]
    var cached = false
    var pendingChanges = false
}

extension APIClient {
    func statisticsSnapshot() async throws -> StatisticsSnapshot {
        let value = try await snapshot()
        return StatisticsSnapshot(garments: value.garments.filter { !$0.deleted }.map(\.display), wears: value.wears)
    }
}

struct GarmentStatistics: Identifiable, Sendable {
    var id: UUID { garment.id }
    let garment: Garment
    let dates: Set<String>
    let activityDays: Int
    let cost: CostPerWear
    var neverWorn: Bool { dates.isEmpty && (garment.initialWearHistory?.count ?? 0) == 0 }

    func unused(since cutoff: String) -> Bool {
        // An estimate gives no last-worn date. Only a boundary at/before the
        // cutoff proves that all estimated wears predate the selected threshold.
        guard dates.max().map({ $0 <= cutoff }) ?? true else { return false }
        if let history = garment.initialWearHistory, history.count > 0 {
            return history.startDate <= cutoff
        }
        // A garment with no dated history may be newly added, not 90 days idle.
        return !dates.isEmpty
    }
}

struct WardrobeStatistics: Sendable {
    enum Period: String, CaseIterable { case all, month, quarter, year }
    let rows: [GarmentStatistics]
    let knownValueGrosz: Decimal
    let missingPrices: Int
    let cutoff90: String

    init(snapshot: StatisticsSnapshot, period: Period, includeArchived: Bool, now: Date = Date(), timezone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let todayKey = formatter.string(from: today)
        cutoff90 = formatter.string(from: calendar.date(byAdding: .day, value: -90, to: today)!)
        let days: Int? = switch period { case .all: nil; case .month: 30; case .quarter: 90; case .year: 365 }
        let start = days.map { formatter.string(from: calendar.date(byAdding: .day, value: 1 - $0, to: today)!) }
        var dates: [UUID: Set<String>] = [:]
        for wear in snapshot.wears where !wear.deleted {
            for id in Set(wear.garmentIDs) { dates[id, default: []].insert(wear.wornOn) }
        }
        rows = snapshot.garments.filter { includeArchived || !$0.archived }.map { garment in
            let worn = dates[garment.id, default: []]
            let active = worn.filter { $0 <= todayKey && (start == nil || $0 >= start!) }.count
            return GarmentStatistics(garment: garment, dates: worn, activityDays: active,
                cost: CostPerWear(priceGrosz: garment.priceGrosz, wornOn: Array(worn), initialHistory: garment.initialWearHistory))
        }
        knownValueGrosz = rows.reduce(Decimal.zero) { $0 + Decimal(max(0, $1.garment.priceGrosz ?? 0)) }
        missingPrices = rows.filter { $0.garment.priceGrosz == nil }.count
    }
    var mostWorn: [GarmentStatistics] {
        rows.filter { $0.activityDays > 0 }.sorted { a,b in
            a.activityDays == b.activityDays ? a.id.uuidString < b.id.uuidString : a.activityDays > b.activityDays
        }
    }
    var neverWorn: [GarmentStatistics] { rows.filter(\.neverWorn).sorted { $0.id.uuidString < $1.id.uuidString } }
    var unused90: [GarmentStatistics] { rows.filter { $0.unused(since: cutoff90) }.sorted { $0.id.uuidString < $1.id.uuidString } }
    var costRanking: [GarmentStatistics] {
        rows.filter { $0.cost.priceGrosz != nil && $0.cost.wearDays > 0 }.sorted { a,b in
            // Compare exact rational values before display rounding. Decimal
            // products avoid overflowing Int64 for high but valid prices.
            let left = Decimal(a.cost.priceGrosz!) * Decimal(b.cost.wearDays)
            let right = Decimal(b.cost.priceGrosz!) * Decimal(a.cost.wearDays)
            return left == right ? a.id.uuidString < b.id.uuidString : left < right
        }
    }
}

@MainActor
final class StatisticsModel: ObservableObject {
    @Published private(set) var snapshot: StatisticsSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var errorKey: String?
    private let repository: any WardrobeRepository
    init(repository: any WardrobeRepository) { self.repository = repository }
    func load() async {
        guard !loading else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do { snapshot = try await repository.statisticsSnapshot() }
        catch {
            if !(error is CancellationError) {
                snapshot = nil
                errorKey = error as? RepositoryError == .backendNotConfigured ? "foundation.serviceUnavailable" : "foundation.loadFailed"
            }
        }
    }
}
