import Combine
import Foundation

struct SuggestionResult: Decodable, Equatable, Sendable {
    struct Proposal: Decodable, Equatable, Sendable {
        let garment_ids: [UUID]
        let rationale: String
    }
    let outfits: [Proposal]
    let shortfall_reason: String?
}

protocol SuggestionRepository: Sendable {
    func latestSuggestions() async throws -> SuggestionResult?
}
struct UnconfiguredSuggestionRepository: SuggestionRepository {
    func latestSuggestions() async throws -> SuggestionResult? { throw RepositoryError.backendNotConfigured }
}
extension APIClient: SuggestionRepository {
    func latestSuggestions() async throws -> SuggestionResult? {
        let response: APIv1.Success<SuggestionResult?> = try await call("api_v1_latest_suggestions", [String: String]())
        return response.data
    }
}

struct Suggestion: Identifiable {
    var outfit: Outfit
    var rationale: String
    var edited = false
    var worn = false
    var id: UUID { outfit.id }
    var missing: [APIv1.Category] {
        let categories = Set(outfit.garments.map(\.category))
        var result: [APIv1.Category] = []
        if !categories.contains(.dress) && !categories.contains(.jumpsuit) {
            if !categories.contains(.top) { result.append(.top) }
            if !categories.contains(.bottom) { result.append(.bottom) }
        }
        if !categories.contains(.shoes) { result.append(.shoes) }
        return result
    }
}

@MainActor
final class SuggestionsModel: ObservableObject {
    @Published private(set) var items: [Suggestion] = []
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var shortfall: String?
    let wardrobe: any WardrobeRepository
    let saves: OutfitsModel
    private let source: any SuggestionRepository
    private let offline: OfflineStore?
    private var lastResult: SuggestionResult?

    init(source: any SuggestionRepository, wardrobe: any WardrobeRepository,
         outfits: any OutfitRepository, offline: OfflineStore?) {
        self.source = source; self.wardrobe = wardrobe; self.offline = offline
        saves = OutfitsModel(repository: SuggestionSaveRepository(base: outfits))
    }

    func load() async {
        guard !loading, !busy, saves.pending == nil else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do {
            let result = try await source.latestSuggestions()
            let garments = try await wardrobe.garments()
            var resolved: [Suggestion] = []
            for proposal in result?.outfits ?? [] {
                guard !proposal.garment_ids.isEmpty, proposal.garment_ids.count <= 40,
                      Set(proposal.garment_ids).count == proposal.garment_ids.count,
                      !proposal.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw APIClientError.invalidResponse
                }
                let selected = try proposal.garment_ids.map { id in
                    guard let garment = garments.first(where: { $0.id == id }), eligible(garment) else {
                        throw APIClientError.invalidResponse
                    }
                    return garment
                }
                resolved.append(Suggestion(outfit: Outfit(name: String(localized: "suggestions.name"), garments: selected),
                                           rationale: proposal.rationale))
            }
            guard resolved.count <= 10 else { throw APIClientError.invalidResponse }
            try Task.checkCancellation()
            // Keep edits and pending user intents when refreshing the same screen.
            if items.isEmpty || result != lastResult {
                items = resolved; shortfall = result?.shortfall_reason; lastResult = result
            }
        } catch { fail(error) }
    }

    func replace(suggestionID: UUID, garmentID: UUID, with replacement: Garment) async {
        guard !busy, !loading, saves.pending == nil,
              let index = items.firstIndex(where: { $0.id == suggestionID }),
              let slot = items[index].outfit.garments.firstIndex(where: { $0.id == garmentID }) else { return }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            let current = try await wardrobe.garments()
            guard let candidate = current.first(where: { $0.id == replacement.id }), eligible(candidate),
                  !items[index].outfit.garments.contains(where: { $0.id == candidate.id }) else {
                throw APIClientError.invalidRequest
            }
            items[index].outfit.garments[slot] = candidate
            items[index].edited = true
            items[index].worn = false
        } catch { fail(error) }
    }

    func save(_ id: UUID) async {
        guard !busy, !loading, let index = items.firstIndex(where: { $0.id == id }),
              saves.pending == nil || saves.pending?.id == id else { return }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            // Retry an ambiguous write verbatim; the server owns final validation.
            if saves.pending == nil { try await validate(items[index].outfit) }
            if await saves.save(items[index].outfit), let saved = saves.items.first(where: { $0.id == id }) {
                items[index].outfit = saved
            } else { errorKey = saves.errorKey }
        } catch { fail(error) }
    }

    func wear(_ id: UUID, now: Date = Date(), timezone: TimeZone = .current) async {
        guard !busy, !loading, saves.pending == nil,
              let index = items.firstIndex(where: { $0.id == id }), !items[index].worn else { return }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            guard let offline else { throw RepositoryError.backendNotConfigured }
            try await validate(items[index].outfit)
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"
            try await offline.recordWear(wornOn: formatter.string(from: now), timezone: timezone.identifier,
                                         garmentIDs: items[index].outfit.garments.map(\.id))
            items[index].worn = true
        } catch { fail(error) }
    }

    private func eligible(_ garment: Garment) -> Bool { !garment.archived && garment.availability == .available }
    private func validate(_ outfit: Outfit) async throws {
        let current = try await wardrobe.garments()
        guard outfit.garments.allSatisfy({ selected in current.contains { $0.id == selected.id && eligible($0) } }) else {
            throw APIClientError.invalidRequest
        }
    }
    private func fail(_ error: any Error) {
        if error is CancellationError { return }
        errorKey = error as? RepositoryError == .backendNotConfigured ? "foundation.serviceUnavailable"
            : error is URLError ? "outfits.offline" : "suggestions.failed"
    }
}

// Route suggestion saves through atomic eligibility checks without changing the
// manual outfit editor, which intentionally supports archived historical items.
private struct SuggestionSaveRepository: OutfitRepository {
    let base: any OutfitRepository
    func outfits(cursor: UUID?) async throws -> OutfitPage { try await base.outfits(cursor: cursor) }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit { try await base.saveSuggestion(request) }
}
