import Foundation

/// Feature read model; versioned wire DTOs stay in the data layer.
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
