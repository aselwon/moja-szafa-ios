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
    func outfits(cursor: UUID?) async throws -> OutfitPage
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit
}

struct UnconfiguredOutfitRepository: OutfitRepository {
    func outfits(cursor: UUID?) async throws -> OutfitPage { throw RepositoryError.backendNotConfigured }
    func saveOutfit(_ request: SaveOutfit) async throws -> Outfit { throw RepositoryError.backendNotConfigured }
}

extension APIClient: OutfitRepository {
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
