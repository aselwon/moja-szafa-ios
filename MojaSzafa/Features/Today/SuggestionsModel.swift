import Combine
import Foundation

struct SuggestionResult: Codable, Equatable, Sendable {
    struct Proposal: Codable, Equatable, Sendable {
        let garment_ids: [UUID]
        let rationale: String
    }
    let outfits: [Proposal]
    let shortfall_reason: String?
}

protocol SuggestionRepository: Sendable {
    func latestSuggestions() async throws -> SuggestionResult?
    func generate(_ request: GenerationRequest) async throws -> GenerationAdmission
    func generationResult(jobID: UUID) async throws -> GenerationJob
}
extension SuggestionRepository {
    func generate(_ request: GenerationRequest) async throws -> GenerationAdmission { throw RepositoryError.backendNotConfigured }
    func generationResult(jobID: UUID) async throws -> GenerationJob { throw RepositoryError.backendNotConfigured }
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

private enum SuggestionResolutionError: Error { case staleGarments }

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
    @Published private(set) var pendingGeneration: GenerationIntent?
    @Published private(set) var generating = false
    @Published private(set) var generationStatus: APIv1.JobStatus?
    @Published private(set) var generationError: String?
    private let intentURL: URL?
    private var intentReadable = true
    private let pollDelay: @Sendable () async throws -> Void

    init(source: any SuggestionRepository, wardrobe: any WardrobeRepository,
         outfits: any OutfitRepository, offline: OfflineStore?, intentURL: URL? = nil,
         pollDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }) {
        self.intentURL = intentURL; self.pollDelay = pollDelay
        self.source = source; self.wardrobe = wardrobe; self.offline = offline
        saves = OutfitsModel(repository: SuggestionSaveRepository(base: outfits))
        if let intentURL, FileManager.default.fileExists(atPath: intentURL.path) {
            do { pendingGeneration = try JSONDecoder().decode(GenerationIntent.self, from: Data(contentsOf: intentURL)) }
            catch { intentReadable = false; generationError = "generation.storage" }
        }
    }

    func load() async {
        guard !generating, pendingGeneration == nil, !loading, !busy, saves.pending == nil else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do {
            let result = try await source.latestSuggestions()
            try await apply(result)
        } catch { fail(error) }
    }

    func replace(suggestionID: UUID, garmentID: UUID, with replacement: Garment) async {
        guard !generating, !busy, !loading, saves.pending == nil,
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
        guard !generating, !busy, !loading, let index = items.firstIndex(where: { $0.id == id }),
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
        guard !generating, !busy, !loading, saves.pending == nil,
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

    // Persist before admission: a lost response must replay exactly the same intent,
    // including after navigation or relaunch. Never replace an ambiguous request.
    func generate(count: Int, weather: GenerationWeatherContext? = nil, maxPolls: Int = 60) async {
        guard intentReadable, !generating, !loading, !busy, saves.pending == nil else { return }
        generating = true; generationError = nil
        defer { generating = false }
        do {
            if pendingGeneration == nil {
                let request = GenerationRequest(operation_id: UUID(), count: count, weather: weather)
                try request.validate()
                try persist(GenerationIntent(request: request, jobID: nil))
            }
            guard var intent = pendingGeneration else { return }
            if intent.jobID == nil {
                let admitted = try await source.generate(intent.request)
                try Task.checkCancellation()
                intent.jobID = admitted.job_id
                try persist(intent)
                generationStatus = admitted.status
            }
            guard let jobID = intent.jobID else { throw APIClientError.invalidResponse }
            for attempt in 0..<max(1, maxPolls) {
                try Task.checkCancellation()
                let job = try await source.generationResult(jobID: jobID)
                try Task.checkCancellation()
                guard job.job_id == jobID, job.kind == .outfitGeneration,
                      (job.status == .succeeded) == (job.result != nil) else { throw APIClientError.invalidResponse }
                generationStatus = job.status
                switch job.status {
                case .queued, .running:
                    if attempt + 1 < maxPolls { try await pollDelay() }
                case .succeeded:
                    guard (job.result?.outfits.count ?? 0) <= intent.request.count else { throw APIClientError.invalidResponse }
                    do { try await apply(job.result) }
                    catch SuggestionResolutionError.staleGarments {
                        // The server finished this job, but the wardrobe changed.
                        // A new explicit intent is safe; transport failures below
                        // retain the existing job and never enqueue a replacement.
                        try persist(nil)
                        generationError = "generation.stale"
                        return
                    }
                    try persist(nil)
                    return
                case .failed, .cancelled, .deadLetter:
                    try persist(nil)
                    generationError = "generation.failed"
                    return
                }
            }
            generationError = "generation.waiting"
        } catch is CancellationError {
            // Keep the durable intent. The account-bound view cancels on exit.
        } catch {
            if let failure = error as? APIv1.Failure {
                switch failure.code {
                case "consent_required": generationError = "generation.consent"
                case "quota_exceeded": generationError = "generation.quota"
                case "ai_disabled": generationError = "generation.disabled"
                case "unauthorized", "account_unavailable": generationError = "generation.account"
                case "validation_failed": generationError = "generation.invalid"
                default: generationError = "generation.failed"
                }
            } else if error is URLError { generationError = "outfits.offline" }
            else if error as? RepositoryError == .backendNotConfigured { generationError = "foundation.serviceUnavailable" }
            else if error is AuthError { generationError = "generation.account" }
            else { generationError = "generation.failed" }
        }
    }

    private func persist(_ intent: GenerationIntent?) throws {
        if let intentURL {
            if let intent {
                try FileManager.default.createDirectory(at: intentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(intent).write(to: intentURL, options: [.atomic, .completeFileProtection])
            } else if FileManager.default.fileExists(atPath: intentURL.path) {
                try FileManager.default.removeItem(at: intentURL)
            }
        }
        pendingGeneration = intent
    }

    private func apply(_ result: SuggestionResult?) async throws {
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
                    throw SuggestionResolutionError.staleGarments
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

struct GenerationWeatherContext: Codable, Equatable, Sendable {
    let temperature_celsius: Double
    let source: String
    let valid_until: Int?
}

struct GenerationRequest: Codable, Equatable, Sendable {
    let operation_id: UUID
    let count: Int
    let weather: GenerationWeatherContext?
    func validate() throws { guard (1...10).contains(count) else { throw APIClientError.invalidRequest } }
    enum CodingKeys: String, CodingKey { case operation_id, count, pinned_garment_id, preferences, occasion, weather }
    init(operation_id: UUID, count: Int, weather: GenerationWeatherContext? = nil) { self.operation_id = operation_id; self.count = count; self.weather = weather }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operation_id = try c.decode(UUID.self, forKey: .operation_id); count = try c.decode(Int.self, forKey: .count)
        weather = try c.decodeIfPresent(GenerationWeatherContext.self, forKey: .weather)
        try validate()
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operation_id, forKey: .operation_id); try c.encode(count, forKey: .count)
        try c.encodeNil(forKey: .pinned_garment_id)
        try c.encode(["colors": [String](), "seasons": [String]()], forKey: .preferences)
        try c.encode(["formality": Optional<Int>.none], forKey: .occasion)
        try c.encodeIfPresent(weather, forKey: .weather)
    }
}
struct GenerationIntent: Codable, Sendable {
    let request: GenerationRequest
    var jobID: UUID?
}
struct GenerationAdmission: Decodable, Sendable {
    let job_id: UUID
    let status: APIv1.JobStatus
}
struct GenerationJob: Decodable, Sendable {
    let job_id: UUID
    let kind: APIv1.JobKind
    let status: APIv1.JobStatus
    let result: SuggestionResult?
    let error_code: String?
}
extension APIClient {
    func generate(_ request: GenerationRequest) async throws -> GenerationAdmission {
        try request.validate()
        let response: APIv1.Success<GenerationAdmission> = try await call("api_v1_generate_outfits", request)
        return response.data
    }
    func generationResult(jobID: UUID) async throws -> GenerationJob {
        let response: APIv1.Success<GenerationJob> = try await call("api_v1_job_result", ["job_id": jobID])
        return response.data
    }
}
