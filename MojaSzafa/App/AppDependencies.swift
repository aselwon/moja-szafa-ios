/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    let wardrobe: any WardrobeRepository

    static func configured(client: APIClient) -> AppDependencies {
        AppDependencies(wardrobe: APIWardrobeRepository(client: client))
    }

    static func live() -> AppDependencies {
        AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
    }
}
