import Foundation
import CryptoKit

/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    var planner: any PlannerRepository = UnconfiguredPlannerRepository()
    var plannerJournalURL: URL?
    var outfits: any OutfitRepository = UnconfiguredOutfitRepository()
    var accountDeletion: (any AccountDeletionService)?
    var deletionCleanup: (@MainActor @Sendable () async throws -> Void)?
    var dataExports: (any DataExportService)?
    var aiConsent: (any AIConsentService)?
    let wardrobe: any WardrobeRepository
    let authentication: any AuthenticationService
    var offline: OfflineStore? { wardrobe as? OfflineStore }
    private var apiConnection: APIConnection?

    private struct APIConnection: Sendable {
        let baseURL: URL
        let transport: any APITransport
        let publicAPIKey: String?
        var identifier: String {
            SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Credentials from one configured gateway must never be sent to another.
    var sessionStoreService: String {
        let app = Bundle.main.bundleIdentifier ?? "pl.mojaszafa.app"
        return "\(app).gateway.\(apiConnection?.identifier ?? "unconfigured")"
    }

    init(wardrobe: any WardrobeRepository, authentication: any AuthenticationService = UnconfiguredAuthenticationService()) {
        self.wardrobe = wardrobe
        self.authentication = authentication
    }

    static func configured(client: APIClient, accountID: UUID, storageDirectory: URL) throws -> AppDependencies {
        let database = OfflineDatabase(url: storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathExtension("sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: client)
        var result = AppDependencies(wardrobe: store)
        result.outfits = client
        result.planner = client
        result.plannerJournalURL = storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathComponent("planner-pending.json")
        result.aiConsent = client
        result.dataExports = client.dataExports
        return result
    }

    /// The native gateway uses the existing auth DTO and bearer-authenticated RPC contract.
    static func configured(baseURL: URL, authentication: any AuthenticationService,
                           transport: any APITransport, publicAPIKey: String? = nil) throws -> AppDependencies {
        _ = try APIClient(baseURL: baseURL, transport: transport, publicAPIKey: publicAPIKey) { throw AuthError.expired }
        var result = AppDependencies(wardrobe: UnconfiguredWardrobeRepository(), authentication: authentication)
        result.apiConnection = APIConnection(baseURL: baseURL, transport: transport, publicAPIKey: publicAPIKey)
        return result
    }

    @MainActor
    func authenticated(using model: AuthenticationModel,
                       storageDirectory: URL = .applicationSupportDirectory) -> AppDependencies {
        guard let connection = apiConnection else { return self }
        do {
            guard let userID = model.session?.userID else { throw AuthError.expired }
            let client = try APIClient(baseURL: connection.baseURL, transport: connection.transport,
                                       publicAPIKey: connection.publicAPIKey,
                                       unauthorized: { token in await model.rejectSession(accessToken: token) }) {
                try await model.accessToken(for: userID)
            }
            let database = OfflineDatabase(url: storageDirectory.appendingPathComponent("Wardrobe")
                .appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString + ".sqlite"))
            let store = try OfflineStore(accountID: userID, database: database, remote: client)
            var result = AppDependencies(wardrobe: store, authentication: authentication)
            result.outfits = client
            result.planner = client
            let plannerDirectory = storageDirectory.appendingPathComponent("Planner").appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString)
            result.plannerJournalURL = plannerDirectory.appendingPathComponent("pending.json")
            result.aiConsent = client
            result.dataExports = client.dataExports
            result.accountDeletion = AccountDeletionClient(baseURL: connection.baseURL, transport: connection.transport,
                                                            accessToken: { try await model.accessToken(for: userID) })
            let accountID = model.session?.userID
            result.deletionCleanup = {
                guard let accountID else { throw AuthError.expired }
                guard model.session?.userID == accountID else { return }
                try await store.invalidateAccount()
                if FileManager.default.fileExists(atPath: plannerDirectory.path) { try FileManager.default.removeItem(at: plannerDirectory) }
                try ProfileStore.local.remove(accountID: accountID)
                let drafts = URL.applicationSupportDirectory.appendingPathComponent("PhotoDrafts")
                    .appendingPathComponent(accountID.uuidString)
                if FileManager.default.fileExists(atPath: drafts.path) { try FileManager.default.removeItem(at: drafts) }
                let exports = DataExportClient.temporaryDirectory
                if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
                try model.finishAccountDeletion(accountID: accountID)
            }
            return result
        } catch { return AppDependencies(wardrobe: UnconfiguredWardrobeRepository(), authentication: authentication) }
    }

    static func live() -> AppDependencies {
        live(backendBaseURL: Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
             transport: URLSessionTransport.gateway())
    }

    /// Build settings supply only a public HTTPS gateway address. Empty, unresolved
    /// or unsafe configuration remains explicitly unavailable without network calls.
    static func live(backendBaseURL: String?, transport: any APITransport) -> AppDependencies {
        guard let value = backendBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("), let url = URL(string: value) else {
            return AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
        }
        do {
            let authentication = try AuthenticationClient(baseURL: url, transport: transport)
            return try configured(baseURL: url, authentication: authentication, transport: transport)
        } catch {
            return AppDependencies(wardrobe: UnconfiguredWardrobeRepository())
        }
    }
}
