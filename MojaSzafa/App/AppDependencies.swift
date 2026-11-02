import Foundation

/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    let wardrobe: any WardrobeRepository
    var offline: OfflineStore? { wardrobe as? OfflineStore }

    static func configured(client: APIClient, accountID: UUID, storageDirectory: URL) throws -> AppDependencies {
        let database = OfflineDatabase(url: storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathExtension("sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: client)
        return AppDependencies(wardrobe: store)
    }

    static func live() -> AppDependencies {
        AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
    }
}
