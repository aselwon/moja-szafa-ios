import Foundation
import CryptoKit

/// Composition root. Features receive protocols, not global service singletons.
struct AppDependencies: Sendable {
    var subscriptions: SubscriptionService?
    var telemetry: TelemetryRecorder?
    var trips: any TripRepository = UnconfiguredTripRepository()
    var tripJournalURL: URL?
    var planner: any PlannerRepository = UnconfiguredPlannerRepository()
    var plannerJournalURL: URL?
    var purchases: (any PurchaseRepository)?
    var weather: (any WeatherForecastRepository)?
    var suggestions: any SuggestionRepository = UnconfiguredSuggestionRepository()
    var wearStore: OfflineStore?
    var outfits: any OutfitRepository = UnconfiguredOutfitRepository()
    var accountDeletion: (any AccountDeletionService)?
    var deletionJournalURL: URL?
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

    func purchaseDirectory(accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("PurchaseDrafts")
            .appendingPathComponent(sessionStoreService).appendingPathComponent(accountID.uuidString)
    }

    func reviewDecisionsURL(accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("WardrobeReview")
            .appendingPathComponent(sessionStoreService).appendingPathComponent(accountID.uuidString + ".json")
    }

    func personalizationIntentURL(accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("PersonalizationIntents")
            .appendingPathComponent(sessionStoreService).appendingPathComponent(accountID.uuidString + ".json")
    }

    func generationIntentURL(accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("GenerationIntents")
            .appendingPathComponent(sessionStoreService)
            .appendingPathComponent(accountID.uuidString + ".json")
    }

    init(wardrobe: any WardrobeRepository, authentication: any AuthenticationService = UnconfiguredAuthenticationService()) {
        self.wardrobe = wardrobe
        self.authentication = authentication
    }

    static func configured(client: APIClient, accountID: UUID, storageDirectory: URL) throws -> AppDependencies {
        let database = OfflineDatabase(url: storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathExtension("sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: client)
        var result = AppDependencies(wardrobe: store)
        result.purchases = client
        result.weather = client
        result.outfits = client
        result.trips = client
        result.tripJournalURL = storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathComponent("trip-pending.json")
        result.planner = client
        result.plannerJournalURL = storageDirectory.appendingPathComponent(accountID.uuidString).appendingPathComponent("planner-pending.json")
        result.suggestions = client
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
            var client = try APIClient(baseURL: connection.baseURL, transport: connection.transport,
                                       publicAPIKey: connection.publicAPIKey,
                                       unauthorized: { token in await model.rejectSession(accessToken: token) }) {
                try await model.accessToken(for: userID)
            }
            let telemetryURL = storageDirectory.appendingPathComponent("Telemetry")
                .appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString + ".json")
            // Optional diagnostics must not disable the wardrobe if its private
            // journal is unreadable; collection stays unavailable and fails closed.
            let telemetry = try? TelemetryRecorder(repository: client, journalURL: telemetryURL)
            client.telemetry = telemetry
            let database = OfflineDatabase(url: storageDirectory.appendingPathComponent("Wardrobe")
                .appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString + ".sqlite"))
            let store = try OfflineStore(accountID: userID, database: database, remote: client, telemetry: telemetry)
            var result = AppDependencies(wardrobe: store, authentication: authentication)
            result.telemetry = telemetry
            if let products = SubscriptionConfiguration.configured() {
                result.subscriptions = SubscriptionService(configuration: products, accountID: userID,
                    storefront: StoreKitStorefront(configuration: products, accountID: userID),
                    receiver: client)
            }
            result.purchases = client
            result.weather = client
            result.apiConnection = connection
            result.wearStore = store
            result.outfits = client
            result.trips = client
            let tripDirectory = storageDirectory.appendingPathComponent("Trips").appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString)
            result.tripJournalURL = tripDirectory.appendingPathComponent("pending.json")
            result.planner = client
            let plannerDirectory = storageDirectory.appendingPathComponent("Planner").appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString)
            result.plannerJournalURL = plannerDirectory.appendingPathComponent("pending.json")
            result.suggestions = client
            result.aiConsent = client
            result.dataExports = client.dataExports
            result.deletionJournalURL = storageDirectory.appendingPathComponent("DeletionProgress").appendingPathComponent(connection.identifier).appendingPathComponent(userID.uuidString + ".json")
            result.accountDeletion = AccountDeletionClient(baseURL: connection.baseURL, transport: connection.transport,
                                                            accessToken: { try await model.accessToken(for: userID) })
            let purchaseDrafts = result.purchaseDirectory(accountID: userID)
            let generationIntent = result.generationIntentURL(accountID: userID)
            let personalizationIntent = result.personalizationIntentURL(accountID: userID)
            let reviewDecisions = result.reviewDecisionsURL(accountID: userID)
            let accountID = model.session?.userID
            let subscriptions = result.subscriptions
            result.deletionCleanup = {
                guard let accountID else { throw AuthError.expired }
                guard model.session?.userID == accountID else { throw AuthError.expired }
                await subscriptions?.stop()
                try await telemetry?.invalidate()
                if FileManager.default.fileExists(atPath: telemetryURL.path) { try FileManager.default.removeItem(at: telemetryURL) }
                try await store.invalidateAccount()
                if FileManager.default.fileExists(atPath: tripDirectory.path) { try FileManager.default.removeItem(at: tripDirectory) }
                if FileManager.default.fileExists(atPath: reviewDecisions.path) { try FileManager.default.removeItem(at: reviewDecisions) }
                if FileManager.default.fileExists(atPath: personalizationIntent.path) { try FileManager.default.removeItem(at: personalizationIntent) }
                if FileManager.default.fileExists(atPath: plannerDirectory.path) { try FileManager.default.removeItem(at: plannerDirectory) }
                if FileManager.default.fileExists(atPath: purchaseDrafts.path) { try FileManager.default.removeItem(at: purchaseDrafts) }
                try ProfileStore.local.remove(accountID: accountID)
                if FileManager.default.fileExists(atPath: generationIntent.path) {
                    try FileManager.default.removeItem(at: generationIntent)
                }
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

    /// Recover accepted deletions even when the provider has already removed the
    /// login session. Only validated journals in this gateway's namespace apply.
    @MainActor
    func recoverDeletions(using model: AuthenticationModel, active: AppDependencies?, activeAccountID: UUID?,
                          storageDirectory: URL = .applicationSupportDirectory) async {
        guard let connection = apiConnection else { return }
        let directory = storageDirectory.appendingPathComponent("DeletionProgress").appendingPathComponent(connection.identifier)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        let receiptClient = AccountDeletionClient(baseURL: connection.baseURL, transport: connection.transport,
                                                 accessToken: { throw AuthError.expired })
        for file in files where file.pathExtension == "json" {
            guard let accountID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      var progress = try DeletionProgress.read(from: file, operationID: accountID) else { continue }
                if !progress.accepted {
                    guard let challenge = progress.challenge, let token = challenge.receiptToken,
                          try await receiptClient.receipt(operationID: accountID, challengeID: challenge.id, token: token) else { continue }
                    progress = DeletionProgress(operationID: accountID, challenge: nil, accepted: true)
                    try progress.write(to: file)
                }
                // Fence live actors before clearing disk. Their in-flight replies
                // cannot restore erased data after the account is invalidated.
                if activeAccountID == accountID {
                    await active?.subscriptions?.stop()
                    try await active?.telemetry?.invalidate()
                    try await active?.offline?.invalidateAccount()
                }
                let client = try APIClient(baseURL: connection.baseURL, transport: connection.transport,
                                           publicAPIKey: connection.publicAPIKey) { throw AuthError.expired }
                let database = OfflineDatabase(url: storageDirectory.appendingPathComponent("Wardrobe")
                    .appendingPathComponent(connection.identifier).appendingPathComponent(accountID.uuidString + ".sqlite"))
                let offline = try OfflineStore(accountID: accountID, database: database, remote: client)
                try await offline.invalidateAccount()
                var paths = ["Trips", "Planner"].map {
                    storageDirectory.appendingPathComponent($0).appendingPathComponent(connection.identifier).appendingPathComponent(accountID.uuidString)
                }
                paths.append(storageDirectory.appendingPathComponent("Telemetry").appendingPathComponent(connection.identifier).appendingPathComponent(accountID.uuidString + ".json"))
                paths += [purchaseDirectory(accountID: accountID), reviewDecisionsURL(accountID: accountID),
                          personalizationIntentURL(accountID: accountID), generationIntentURL(accountID: accountID),
                          URL.applicationSupportDirectory.appendingPathComponent("PhotoDrafts").appendingPathComponent(accountID.uuidString)]
                for path in paths where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                try ProfileStore.local.remove(accountID: accountID)
                if model.session == nil || model.session?.userID == accountID {
                    let exports = DataExportClient.temporaryDirectory
                    if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
                }
                try model.finishAccountDeletion(accountID: accountID)
                try FileManager.default.removeItem(at: file)
            } catch {
                // Keep the durable receipt and retry next foreground. Never turn
                // a failed/unknown recovery into a second deletion request.
                continue
            }
        }
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
