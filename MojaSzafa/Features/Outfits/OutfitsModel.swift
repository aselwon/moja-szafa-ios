import Combine
import Foundation

struct Outfit: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var version: Int64 = 0
    var name = ""
    var favorite = false
    var garmentIDs: [UUID] = []

    func validate() throws {
        guard (1...200).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count),
              (1...100).contains(garmentIDs.count), Set(garmentIDs).count == garmentIDs.count else {
            throw APIClientError.invalidRequest
        }
    }
}

struct SaveOutfit: Encodable, Sendable {
    let operationID: UUID
    let outfit: Outfit

    enum CodingKeys: String, CodingKey { case operationID = "operation_id", id = "outfit_id", version = "base_version", outfit }
    struct Fields: Encodable { let name: String; let favorite: Bool; let garmentIDs: [UUID] }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(outfit.id, forKey: .id)
        if outfit.version == 0 { try c.encodeNil(forKey: .version) }
        else { try c.encode(outfit.version, forKey: .version) }
        try c.encode(Fields(name: outfit.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            favorite: outfit.favorite, garmentIDs: outfit.garmentIDs), forKey: .outfit)
    }
}

protocol OutfitRepository: Sendable {
    func outfits() async throws -> [Outfit]
    func saveOutfit(_ operation: SaveOutfit) async throws -> Outfit
}

struct UnconfiguredOutfitRepository: OutfitRepository {
    func outfits() async throws -> [Outfit] { throw RepositoryError.backendNotConfigured }
    func saveOutfit(_ operation: SaveOutfit) async throws -> Outfit { throw RepositoryError.backendNotConfigured }
}

extension APIClient: OutfitRepository {
    func outfits() async throws -> [Outfit] {
        struct Empty: Encodable {}
        let response: APIv1.Success<[Outfit]> = try await call("api_v1_list_outfits", Empty())
        return response.data
    }
    func saveOutfit(_ operation: SaveOutfit) async throws -> Outfit {
        try operation.outfit.validate()
        let response: APIv1.Success<Outfit> = try await call("api_v1_save_outfit", operation)
        guard response.data.id == operation.outfit.id, response.data.version > operation.outfit.version else {
            throw APIClientError.invalidResponse
        }
        return response.data
    }
}

@MainActor
final class OutfitsModel: ObservableObject {
    @Published private(set) var outfits: [Outfit] = []
    @Published private(set) var garments: [Garment] = []
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var loaded = false
    @Published private(set) var errorKey: String?
    @Published private(set) var cached = false
    @Published private(set) var pending: SaveOutfit?
    let wardrobe: any WardrobeRepository
    private let repository: any OutfitRepository

    init(repository: any OutfitRepository, wardrobe: any WardrobeRepository) {
        self.repository = repository; self.wardrobe = wardrobe
    }

    func load() async {
        guard !loading, !saving else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do {
            let saved = try await repository.outfits()
            var all: [Garment] = []
            var isCached = false
            for archived in [false, true] {
                var offset: Int? = 0
                while let current = offset {
                    let page = try await wardrobe.page(query: WardrobeQuery(archived: archived), offset: current, limit: 100)
                    all.append(contentsOf: page.items)
                    isCached = isCached || page.cached
                    offset = page.nextOffset
                }
            }
            try Task.checkCancellation()
            outfits = saved; garments = all; cached = isCached; loaded = true
        } catch { if !Task.isCancelled { errorKey = message(for: error) } }
    }

    func save(_ draft: Outfit) async -> Bool {
        guard !saving else { return false }
        saving = true; errorKey = nil
        defer { saving = false }
        do {
            try draft.validate()
            guard draft.garmentIDs.allSatisfy({ id in garments.contains { $0.id == id } }) else {
                throw APIClientError.invalidRequest
            }
            // Retry an ambiguous timeout with identical bytes and operation UUID.
            // The editor stays locked until this intent succeeds or is rejected.
            let operation = pending ?? SaveOutfit(operationID: UUID(), outfit: draft)
            pending = operation
            let saved = try await repository.saveOutfit(operation)
            outfits.removeAll { $0.id == saved.id }; outfits.append(saved)
            pending = nil
            return true
        } catch {
            if let failure = error as? APIv1.Failure,
               ["version_conflict", "validation_failed", "idempotency_conflict", "account_unavailable"].contains(failure.code) {
                pending = nil
            }
            errorKey = message(for: error)
            return false
        }
    }

    private func message(for error: any Error) -> String {
        if (error as? APIv1.Failure)?.code == "version_conflict" { return "outfits.conflict" }
        if error as? RepositoryError == .backendNotConfigured { return "foundation.serviceUnavailable" }
        if error is URLError { return "outfits.offline" }
        return "outfits.failed"
    }
}
