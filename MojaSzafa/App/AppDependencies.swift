/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    let wardrobe: any WardrobeRepository

    static func live() -> AppDependencies {
        AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
    }
}
