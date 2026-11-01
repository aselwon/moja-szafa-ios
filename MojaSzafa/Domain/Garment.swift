import Foundation

/// Minimal read model; ownership, pricing and sync contracts belong to T008–T012.
struct Garment: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

protocol WardrobeRepository: Sendable {
    func garments() async throws -> [Garment]
}

enum RepositoryError: Error, Equatable {
    case backendNotConfigured
}
