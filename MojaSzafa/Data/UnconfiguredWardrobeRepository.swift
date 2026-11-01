/// Fails explicitly until the real backend and API contracts are implemented.
/// Never returns sample data or a misleading empty wardrobe in production.
struct UnconfiguredWardrobeRepository: WardrobeRepository {
    func garments() async throws -> [Garment] {
        try Task.checkCancellation()
        throw RepositoryError.backendNotConfigured
    }
}
