import Combine
import Foundation

struct Outfit: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var version: Int64 = 0
    var name = ""
    var favorite = false
    var garments: [Garment] = []

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && name.unicodeScalars.count <= 200 && (1...100).contains(garments.count)
        && Set(garments.map(\.id)).count == garments.count
    }
}

struct SaveOutfit: Codable, Equatable, Sendable {
    let operationID: UUID
    let id: UUID
    let baseVersion: Int64
    let name: String
    let favorite: Bool
    let garmentIDs: [UUID]

    init(_ outfit: Outfit, operationID: UUID = UUID()) {
        self.operationID = operationID
        id = outfit.id; baseVersion = outfit.version
        name = outfit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        favorite = outfit.favorite; garmentIDs = outfit.garments.map(\.id)
    }
}

struct OutfitPage: Decodable, Sendable {
    let items: [Outfit]
    let nextCursor: UUID?
}

protocol OutfitRepository: Sendable {
    func personalization(_ request: PersonalizationRequest) async throws -> PersonalizationState
    func outfits(cursor: UUID?) async throws -> OutfitPage
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit
    func saveSuggestion(_ request: SaveOutfit) async throws -> Outfit
}

extension OutfitRepository {
    func personalization(_ request: PersonalizationRequest) async throws -> PersonalizationState { throw RepositoryError.backendNotConfigured }
    func saveSuggestion(_ request: SaveOutfit) async throws -> Outfit { try await saveOutfit(request) }
}

struct UnconfiguredOutfitRepository: OutfitRepository {
    func outfits(cursor: UUID?) async throws -> OutfitPage { throw RepositoryError.backendNotConfigured }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit { throw RepositoryError.backendNotConfigured }
}

extension APIClient: OutfitRepository {
    func personalization(_ request: PersonalizationRequest) async throws -> PersonalizationState {
        let result: APIv1.Success<PersonalizationState> = try await call("api_v1_personalization", request)
        return result.data
    }
    func saveSuggestion(_ request: SaveOutfit) async throws -> Outfit {
        let result: APIv1.Success<Outfit> = try await call("api_v1_save_suggestion", request)
        guard result.data.id == request.id, result.data.version > request.baseVersion else { throw APIClientError.invalidResponse }
        return result.data
    }
    func outfits(cursor: UUID?) async throws -> OutfitPage {
        let result: APIv1.Success<OutfitPage> = try await call("api_v1_list_outfits", APIv1.PageRequest(limit: 40, cursor: cursor))
        return result.data
    }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit {
        let result: APIv1.Success<Outfit> = try await call("api_v1_save_outfit", request)
        guard result.data.id == request.id, result.data.version > request.baseVersion else { throw APIClientError.invalidResponse }
        return result.data
    }
}

@MainActor
final class OutfitsModel: ObservableObject {
    @Published private(set) var items: [Outfit] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var errorKey: String?
    @Published private(set) var nextCursor: UUID?
    @Published private(set) var pending: SaveOutfit?
    private(set) var pendingDraft: Outfit?
    let repository: any OutfitRepository

    init(repository: any OutfitRepository) { self.repository = repository }

    func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do {
            let page = try await repository.outfits(cursor: more ? nextCursor : nil)
            try Task.checkCancellation()
            if more {
                let ids = Set(items.map(\.id))
                items += page.items.filter { !ids.contains($0.id) }
            } else { items = page.items }
            nextCursor = page.nextCursor
        } catch { setError(error) }
    }

    func save(_ outfit: Outfit) async -> Bool {
        guard !saving, outfit.isValid else { return false }
        // Keep the exact payload after an ambiguous timeout. The editor is locked
        // until retry succeeds or a definitive rejection allows a new intent.
        let request = pending ?? SaveOutfit(outfit)
        pendingDraft = pendingDraft ?? outfit
        pending = request; saving = true; errorKey = nil
        defer { saving = false }
        do {
            let saved = try await repository.saveOutfit(request)
            if let index = items.firstIndex(where: { $0.id == saved.id }) { items[index] = saved }
            else { items.insert(saved, at: 0) }
            pending = nil; pendingDraft = nil
            return true
        } catch {
            if error as? RepositoryError == .backendNotConfigured { pending = nil; pendingDraft = nil }
            if let failure = error as? APIv1.Failure {
                if ["validation_failed", "version_conflict", "account_unavailable", "idempotency_conflict"].contains(failure.code) {
                    pending = nil; pendingDraft = nil
                }
                if failure.code == "version_conflict" { errorKey = "outfits.conflict"; return false }
            }
            setError(error)
            return false
        }
    }

    private func setError(_ error: any Error) {
        if error as? RepositoryError == .backendNotConfigured { errorKey = "foundation.serviceUnavailable" }
        else if error is URLError { errorKey = "outfits.offline" }
        else if !(error is CancellationError) { errorKey = "foundation.loadFailed" }
    }
}

struct OutfitFeedback: Codable, Equatable, Sendable {
    let outfitID: UUID
    let rating: String
    let reason: String?
}
struct PersonalizationState: Codable, Equatable, Sendable {
    let version: Int64
    let excludedCategories: [String]
    let colors: [String]
    let feedback: OutfitFeedback?
}
struct PersonalizationRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable { case get, preferences, feedback, reset }
    let action: Action
    var operationID: UUID?
    var baseVersion: Int64?
    var outfitID: UUID?
    var excludedCategories: [String]?
    var colors: [String]?
    var rating: String?
    var reason: String?
}

@MainActor
final class PersonalizationModel: ObservableObject {
    @Published private(set) var state: PersonalizationState?
    @Published private(set) var pending: PersonalizationRequest?
    @Published private(set) var busy = false
    @Published private(set) var errorKey: String?
    private let repository: any OutfitRepository
    private let journalURL: URL?
    private var focus: UUID?
    private var storageFailed = false

    init(repository: any OutfitRepository, journalURL: URL? = nil) {
        self.repository = repository; self.journalURL = journalURL
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) {
            do { pending = try JSONDecoder().decode(PersonalizationRequest.self, from: Data(contentsOf: journalURL)) }
            catch { storageFailed = true; errorKey = "personalization.storage" }
        }
    }
    func load(outfitID: UUID? = nil) async {
        guard !busy, !storageFailed else { return }
        focus = outfitID; state = nil; busy = true; errorKey = nil
        defer { busy = false }
        do { state = try await repository.personalization(PersonalizationRequest(action: .get, outfitID: outfitID)) }
        catch { errorKey = "personalization.failed" }
    }
    func save(action: PersonalizationRequest.Action, excluded: [String]? = nil, colors: [String]? = nil,
              rating: String? = nil, reason: String? = nil) async -> Bool {
        guard !busy, !storageFailed, let state, pending == nil, action != .get else { return false }
        let request = PersonalizationRequest(action: action, operationID: UUID(), baseVersion: state.version,
            outfitID: action == .feedback ? focus : nil, excludedCategories: excluded?.sorted(), colors: colors?.sorted(), rating: rating, reason: reason)
        do { try persist(request); pending = request }
        catch { errorKey = "personalization.storage"; return false }
        return await retry()
    }
    @discardableResult func retry() async -> Bool {
        guard !busy, !storageFailed, let request = pending else { return false }
        busy = true; errorKey = nil
        defer { busy = false }
        do {
            _ = try await repository.personalization(request)
            try persist(nil); pending = nil
            // A replay may return an old acknowledgement after another device's
            // reset. Always read the current revision before permitting edits.
            state = nil
            state = try await repository.personalization(PersonalizationRequest(action: .get, outfitID: focus))
            return true
        } catch {
            if let failure = error as? APIv1.Failure,
               ["version_conflict", "validation_failed", "idempotency_conflict", "account_unavailable"].contains(failure.code) {
                do { try persist(nil); pending = nil; state = nil }
                catch { storageFailed = true }
                errorKey = storageFailed ? "personalization.storage" : "personalization.conflict"
            } else if error as? RepositoryError == .backendNotConfigured {
                do { try persist(nil); pending = nil } catch { storageFailed = true }
                errorKey = "foundation.serviceUnavailable"
            } else { errorKey = "personalization.failed" }
            return false
        }
    }
    private func persist(_ request: PersonalizationRequest?) throws {
        guard let journalURL else { return }
        if let request {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var url = journalURL; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } else if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
    }
}
