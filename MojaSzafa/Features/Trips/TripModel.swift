import Combine
import Foundation

struct TripChoice: Codable, Equatable, Identifiable, Sendable {
    var id: String { day }
    let day: String
    var outfitID: UUID?
    var outfitVersion: Int64?
    enum CodingKeys: String, CodingKey { case day, outfitID, outfitVersion }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(day, forKey: .day); try c.encode(outfitID, forKey: .outfitID); try c.encode(outfitVersion, forKey: .outfitVersion)
    }
}
struct TripBody: Codable, Equatable, Sendable {
    var destination: String
    var startsOn: String
    var endsOn: String
    var timezone: String
    var occasions: [String]
    var maxItems: Int
    var days: [TripChoice]
}
struct TripDay: Codable, Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let outfitID: UUID?
    let outfitVersion: Int64?
    let outfitName: String?
    let garments: [Garment]
    let missingCategories: [String]
    let unavailableIDs: [UUID]
    let repeated: Bool
}
struct PackingItem: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { garment.id }
    let garment: Garment
    let packed: Bool
    var available: Bool { !garment.archived && garment.availability == .available }
}
struct TripPlan: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let version: Int64
    let destination: String
    let startsOn: String
    let endsOn: String
    let timezone: String
    let occasions: [String]
    let maxItems: Int
    let days: [TripDay]
    let packing: [PackingItem]
    var body: TripBody {
        TripBody(destination: destination, startsOn: startsOn, endsOn: endsOn, timezone: timezone, occasions: occasions,
                 maxItems: maxItems, days: days.map { TripChoice(day: $0.day, outfitID: $0.outfitID, outfitVersion: $0.outfitVersion) })
    }
}
struct TripSummary: Decodable, Identifiable, Sendable {
    let id: UUID
    let destination: String
    let startsOn: String
    let endsOn: String
}
struct TripPage: Decodable, Sendable { let items: [TripSummary]; let nextCursor: UUID? }
struct TripMutation: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case save, pack }
    let action: Action
    var operationID = UUID()
    let id: UUID
    let baseVersion: Int64
    var trip: TripBody?
    var garmentID: UUID?
    var packed: Bool?
}
protocol TripRepository: Sendable {
    func trips(cursor: UUID?) async throws -> TripPage
    func trip(id: UUID) async throws -> TripPlan
    func changeTrip(_ request: TripMutation) async throws -> TripPlan
}
struct UnconfiguredTripRepository: TripRepository {
    func trips(cursor: UUID?) async throws -> TripPage { throw RepositoryError.backendNotConfigured }
    func trip(id: UUID) async throws -> TripPlan { throw RepositoryError.backendNotConfigured }
    func changeTrip(_ request: TripMutation) async throws -> TripPlan { throw RepositoryError.backendNotConfigured }
}
extension APIClient: TripRepository {
    func trips(cursor: UUID?) async throws -> TripPage {
        struct Request: Encodable { let action = "list"; let cursor: UUID? }
        let response: APIv1.Success<TripPage> = try await call("api_v1_trips", Request(cursor: cursor))
        return response.data
    }
    func trip(id: UUID) async throws -> TripPlan {
        struct Request: Encodable { let action = "get"; let id: UUID }
        let response: APIv1.Success<TripPlan> = try await call("api_v1_trips", Request(id: id))
        guard response.data.id == id else { throw APIClientError.invalidResponse }
        return response.data
    }
    func changeTrip(_ request: TripMutation) async throws -> TripPlan {
        let response: APIv1.Success<TripPlan> = try await call("api_v1_trips", request)
        guard response.data.id == request.id, response.data.version > request.baseVersion else { throw APIClientError.invalidResponse }
        return response.data
    }
}

/// A transparent, local suggestion: rotate saved outfits that fit the unique-item
/// budget. Reusing garments is deliberate; this is not an AI or weather claim.
enum TripPlanner {
    static func days(from: String, through: String) -> [String] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = .gmt; formatter.dateFormat = "yyyy-MM-dd"
        guard let first = formatter.date(from: from), let last = formatter.date(from: through), last >= first else { return [] }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        guard let count = calendar.dateComponents([.day], from: first, to: last).day, count < 30 else { return [] }
        return (0...count).compactMap { calendar.date(byAdding: .day, value: $0, to: first).map(formatter.string) }
    }
    static func suggest(days: [String], outfits: [Outfit], maxItems: Int) -> [TripChoice] {
        let eligible = outfits.filter { !$0.garments.isEmpty && $0.garments.allSatisfy { !$0.archived && $0.availability == .available } }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var used = Set<UUID>(); var chosenCounts: [UUID: Int] = [:]
        return days.map { day in
            let choice = eligible.filter { used.union($0.garments.map(\.id)).count <= maxItems }
                .min { a, b in
                    let left = chosenCounts[a.id, default: 0], right = chosenCounts[b.id, default: 0]
                    return left == right ? a.id.uuidString < b.id.uuidString : left < right
                }
            if let choice { used.formUnion(choice.garments.map(\.id)); chosenCounts[choice.id, default: 0] += 1 }
            return TripChoice(day: day, outfitID: choice?.id, outfitVersion: choice?.version)
        }
    }
}

@MainActor
final class TripModel: ObservableObject {
    @Published private(set) var items: [TripSummary] = []
    @Published private(set) var nextCursor: UUID?
    @Published private(set) var current: TripPlan?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var errorKey: String?
    @Published private(set) var pending: TripMutation?
    @Published private(set) var undoPacking: TripMutation?
    private let repository: any TripRepository
    private let journalURL: URL?
    private var journalFailed = false
    private var loadID = UUID()
    private var revision = 0

    init(repository: any TripRepository, journalURL: URL? = nil) {
        self.repository = repository; self.journalURL = journalURL
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) {
            do { pending = try JSONDecoder().decode(TripMutation.self, from: Data(contentsOf: journalURL)) }
            catch { journalFailed = true; errorKey = "trips.journalFailed" }
        }
    }
    func loadList(more: Bool = false) async {
        if more && (loading || nextCursor == nil) { return }
        let id = UUID(); loadID = id; loading = true
        defer { if loadID == id { loading = false } }
        do {
            let page = try await repository.trips(cursor: more ? nextCursor : nil)
            try Task.checkCancellation(); guard loadID == id else { return }
            if more { let ids = Set(items.map(\.id)); items += page.items.filter { !ids.contains($0.id) } }
            else { items = page.items }
            nextCursor = page.nextCursor
            if !journalFailed { errorKey = nil }
        } catch { if loadID == id { setError(error) } }
    }
    func load(id tripID: UUID) async {
        let id = UUID(); loadID = id; loading = true; current = nil; undoPacking = nil
        let revision = self.revision
        defer { if loadID == id { loading = false } }
        do {
            let trip = try await repository.trip(id: tripID)
            try Task.checkCancellation(); guard loadID == id, revision == self.revision else { return }
            current = trip; if !journalFailed { errorKey = nil }
        } catch { if loadID == id, revision == self.revision { setError(error) } }
    }
    func change(_ request: TripMutation) async -> Bool {
        guard !saving, !journalFailed, pending == nil || pending == request else { return false }
        saving = true; revision += 1; errorKey = nil
        defer { saving = false }
        do {
            if pending == nil { try persist(request); pending = request }
            let result = try await repository.changeTrip(request)
            try persist(nil); pending = nil; revision += 1; current = result
            if request.action == .pack, let packed = request.packed, let garment = request.garmentID {
                undoPacking = TripMutation(action: .pack, id: result.id, baseVersion: result.version, garmentID: garment, packed: !packed)
            } else { undoPacking = nil }
            return true
        } catch {
            if let failure = error as? APIv1.Failure,
               ["validation_failed", "version_conflict", "account_unavailable", "idempotency_conflict"].contains(failure.code) {
                do { try persist(nil); pending = nil } catch { journalFailed = true }
                errorKey = failure.code == "version_conflict" ? "trips.conflict" : "trips.rejected"
            } else if error as? RepositoryError == .backendNotConfigured {
                do { try persist(nil); pending = nil } catch { journalFailed = true }
                errorKey = "foundation.serviceUnavailable"
            } else { setError(error) }
            return false
        }
    }
    private func persist(_ mutation: TripMutation?) throws {
        guard let journalURL else { return }
        if let mutation {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(mutation).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
    }
    private func setError(_ error: any Error) {
        if journalFailed { errorKey = "trips.journalFailed" }
        else if error as? RepositoryError == .backendNotConfigured { errorKey = "foundation.serviceUnavailable" }
        else if error is URLError { errorKey = "trips.offline" }
        else if !(error is CancellationError) { errorKey = "foundation.loadFailed" }
    }
}
