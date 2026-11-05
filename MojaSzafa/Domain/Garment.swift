import Foundation

/// Read models contain image IDs, never storage keys or persistent signed URLs.
struct Garment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let name: String
    var category: APIv1.Category = .other
    var availability: APIv1.Availability = .available
    var priceGrosz: Int64? = nil
    var imageID: UUID? = nil
    var brand: String? = nil
    var colors: [String] = []
    var seasons: [String] = []
    var archived: Bool = false
    var initialWearHistory: InitialWearHistory? = nil
}

struct WardrobeQuery: Equatable, Encodable, Sendable {
    enum Sort: String, CaseIterable, Encodable, Sendable { case name, nameDescending, price }
    var search = ""
    var category: APIv1.Category? = nil
    var availability: APIv1.Availability? = nil
    var sort: Sort = .name
    var archived = false

    func page(_ garments: [Garment], offset: Int, limit: Int, cached: Bool) -> WardrobePage {
        let filtered = garments.filter {
            $0.archived == archived && (category == nil || $0.category == category)
            && (availability == nil || $0.availability == availability)
            && (search.isEmpty || $0.name.localizedStandardContains(search) || ($0.brand?.localizedStandardContains(search) ?? false))
        }.sorted {
            if sort == .price, $0.priceGrosz != $1.priceGrosz {
                // Unknown prices sort last; zero remains a known price.
                if $0.priceGrosz == nil { return false }
                if $1.priceGrosz == nil { return true }
                return $0.priceGrosz! < $1.priceGrosz!
            }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == (sort == .nameDescending ? .orderedDescending : .orderedAscending)
        }
        return WardrobePage(items: Array(filtered.dropFirst(offset).prefix(limit)),
                            nextOffset: offset + limit < filtered.count ? offset + limit : nil, cached: cached)
    }
}

struct WardrobePage: Decodable, Sendable {
    let items: [Garment]
    let nextOffset: Int?
    var cached = false
}

struct GarmentDetail: Decodable, Sendable {
    let garment: Garment
    /// Distinct local calendar dates from historical wear_event_items, never current outfits.
    let wornOn: [String]
    var cached = false
}

/// An explicit estimate of wear days strictly before the diary boundary.
/// Journal dates remain intact; only dates on/after the boundary add to CPW.
struct InitialWearHistory: Codable, Equatable, Sendable {
    let count: Int
    let startDate: String

    init(count: Int, startDate: String) { self.count = count; self.startDate = startDate }
    enum CodingKeys: String, CodingKey { case count, startDate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        startDate = try c.decode(String.self, forKey: .startDate)
        try validate()
    }

    func validate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard (0...1_000_000).contains(count), let date = formatter.date(from: startDate),
              formatter.string(from: date) == startDate else { throw APIClientError.invalidRequest }
    }
}

/// Exact lifetime ratio. Store the numerator and denominator; round only when
/// rendering currency. No model-generated values or binary floating point.
struct CostPerWear: Equatable, Sendable {
    let priceGrosz: Int64?
    let wearDays: Int
    let isEstimated: Bool

    init(priceGrosz: Int64?, wornOn: [String], initialHistory: InitialWearHistory? = nil) {
        self.priceGrosz = priceGrosz.flatMap { $0 >= 0 ? $0 : nil }
        self.isEstimated = initialHistory != nil
        if let initialHistory {
            self.wearDays = initialHistory.count + Set(wornOn).filter { $0 >= initialHistory.startDate }.count
        } else { self.wearDays = Set(wornOn).count }
    }

    var roundedGrosz: Int64? {
        guard let priceGrosz, wearDays > 0 else { return nil }
        let days = Int64(wearDays)
        let whole = priceGrosz / days
        let remainder = priceGrosz % days
        // Half-up without doubling a remainder or adding to the numerator:
        // both could overflow for valid large prices.
        return whole + (remainder >= days / 2 + days % 2 ? 1 : 0)
    }
}

extension GarmentDetail {
    var costPerWear: CostPerWear { CostPerWear(priceGrosz: garment.priceGrosz, wornOn: wornOn, initialHistory: garment.initialWearHistory) }
}

protocol WardrobeRepository: Sendable {
    func setArchived(id: UUID, archived: Bool) async throws -> GarmentDetail
    func statisticsSnapshot() async throws -> StatisticsSnapshot
    func setInitialHistory(id: UUID, history: InitialWearHistory?, confirmOverlap: Bool) async throws -> GarmentDetail
    func deleteGarment(id: UUID) async throws
    func setStatus(id: UUID, availability: APIv1.Availability, archived: Bool) async throws -> GarmentDetail
    func garments() async throws -> [Garment]
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage
    func detail(id: UUID) async throws -> GarmentDetail
    func thumbnail(imageID: UUID) async throws -> Data
    func original(imageID: UUID) async throws -> Data
}

extension WardrobeRepository {
    func setArchived(id: UUID, archived: Bool) async throws -> GarmentDetail { throw RepositoryError.backendNotConfigured }
    func statisticsSnapshot() async throws -> StatisticsSnapshot { throw RepositoryError.backendNotConfigured }
    func setInitialHistory(id: UUID, history: InitialWearHistory?, confirmOverlap: Bool) async throws -> GarmentDetail { throw RepositoryError.backendNotConfigured }
    func deleteGarment(id: UUID) async throws { throw RepositoryError.backendNotConfigured }
    func setStatus(id: UUID, availability: APIv1.Availability, archived: Bool) async throws -> GarmentDetail {
        throw RepositoryError.backendNotConfigured
    }
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        query.page(try await garments(), offset: offset, limit: limit, cached: false)
    }
    func detail(id: UUID) async throws -> GarmentDetail { throw RepositoryError.backendNotConfigured }
    func thumbnail(imageID: UUID) async throws -> Data { throw RepositoryError.backendNotConfigured }
    func original(imageID: UUID) async throws -> Data { throw RepositoryError.backendNotConfigured }
}

enum RepositoryError: Error, Equatable {
    case backendNotConfigured
}
