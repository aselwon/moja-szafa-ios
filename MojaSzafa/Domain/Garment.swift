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

protocol WardrobeRepository: Sendable {
    func garments() async throws -> [Garment]
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage
    func detail(id: UUID) async throws -> GarmentDetail
    func thumbnail(imageID: UUID) async throws -> Data
    func original(imageID: UUID) async throws -> Data
}

extension WardrobeRepository {
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
