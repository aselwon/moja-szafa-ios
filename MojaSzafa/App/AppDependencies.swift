import Foundation

/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    var aiConsent: (any AIConsentService)?
    let wardrobe: any WardrobeRepository
    let authentication: any AuthenticationService
    var offline: OfflineStore? { wardrobe as? OfflineStore }
    private var apiConnection: APIConnection?

    private struct APIConnection: Sendable {
        let baseURL: URL
        let transport: any APITransport
        let publicAPIKey: String?
    }

    init(wardrobe: any WardrobeRepository, authentication: any AuthenticationService = UnconfiguredAuthenticationService()) {
        self.wardrobe = wardrobe
        self.authentication = authentication
    }

    static func configured(client: APIClient, accountID: UUID, storageDirectory: URL) throws -> AppDependencies {
        let database = OfflineDatabase(url: storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathExtension("sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: client)
        var result = AppDependencies(wardrobe: store)
        result.aiConsent = client
        return result
    }

    /// For the approved gateway deployment. live() intentionally remains locked
    /// until server identity policy and environment endpoints have been verified.
    static func configured(baseURL: URL, authentication: any AuthenticationService,
                           transport: any APITransport, publicAPIKey: String? = nil) throws -> AppDependencies {
        _ = try APIClient(baseURL: baseURL, transport: transport, publicAPIKey: publicAPIKey) { throw AuthError.expired }
        var result = AppDependencies(wardrobe: UnconfiguredWardrobeRepository(), authentication: authentication)
        result.apiConnection = APIConnection(baseURL: baseURL, transport: transport, publicAPIKey: publicAPIKey)
        return result
    }

    @MainActor
    func authenticated(using model: AuthenticationModel) -> AppDependencies {
        guard let connection = apiConnection else { return self }
        do {
            let client = try APIClient(baseURL: connection.baseURL, transport: connection.transport,
                                       publicAPIKey: connection.publicAPIKey,
                                       unauthorized: { token in await model.rejectSession(accessToken: token) }) {
                try await model.accessToken()
            }
            guard let accountID = model.session?.userID else { return self }
            let database = OfflineDatabase(url: URL.applicationSupportDirectory.appendingPathComponent("Wardrobe")
                .appendingPathComponent(accountID.uuidString).appendingPathExtension("sqlite"))
            let store = try OfflineStore(accountID: accountID, database: database, remote: client)
            var result = AppDependencies(wardrobe: store, authentication: authentication)
            result.aiConsent = client
            return result
        } catch { return AppDependencies(wardrobe: UnconfiguredWardrobeRepository(), authentication: authentication) }
    }

    static func live() -> AppDependencies {
        AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
    }
}
