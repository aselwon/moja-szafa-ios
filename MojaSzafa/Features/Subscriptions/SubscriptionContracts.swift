import Foundation

struct SubscriptionConfiguration: Sendable, Equatable {
    let monthlyID: String
    let yearlyID: String

    init?(monthlyID: String?, yearlyID: String?) {
        guard let monthlyID, let yearlyID, monthlyID != yearlyID,
              [monthlyID, yearlyID].allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{2,199}$", options: .regularExpression) != nil }) else { return nil }
        self.monthlyID = monthlyID; self.yearlyID = yearlyID
    }
    var productIDs: Set<String> { [monthlyID, yearlyID] }
    static func configured(bundle: Bundle = .main) -> Self? {
        Self(monthlyID: bundle.object(forInfoDictionaryKey: "StoreKitMonthlyProductID") as? String,
             yearlyID: bundle.object(forInfoDictionaryKey: "StoreKitYearlyProductID") as? String)
    }
}

enum SubscriptionPeriod: String, Sendable { case month, year }
struct SubscriptionProduct: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// Localized by StoreKit. Never reconstruct a price from fixture values.
    let displayPrice: String
    let period: SubscriptionPeriod
    let groupID: String
}

/// A StoreKit-verified transaction, still awaiting authoritative server acceptance.
/// The signed representation remains in memory and is never logged or put in a URL.
struct VerifiedStoreTransaction: Sendable {
    let id: UInt64
    let originalID: UInt64
    let productID: String
    let accountToken: UUID?
    let signedRepresentation: String
}

enum StorePurchaseResult: Sendable {
    case verified(VerifiedStoreTransaction), pending, cancelled
}

enum SubscriptionError: Error, Equatable {
    case unavailable, invalidProducts, unverified, accountMismatch, serverUnavailable, invalidAcknowledgement, inactive, busy
}

protocol SubscriptionStorefront: Sendable {
    func products() async throws -> [SubscriptionProduct]
    func purchase(productID: String) async throws -> StorePurchaseResult
    func synchronize() async throws
    func unfinishedTransactions() async -> [VerifiedStoreTransaction]
    func currentTransactions() async -> [VerifiedStoreTransaction]
    func updates() async -> AsyncStream<VerifiedStoreTransaction>
    func finish(transactionID: UInt64) async
}

struct SubscriptionAcknowledgement: Sendable {
    let transactionID: UInt64
}

protocol SubscriptionTransactionReceiver: Sendable {
    /// False until T050's server verifier is configured. Loading a purchase sheet
    /// must be impossible when the application cannot honor a verified purchase.
    var configured: Bool { get }
    /// Checks the server's current ability to honor this catalog before asking
    /// Apple to charge. Configuration alone does not establish availability.
    func preparePurchase(configuration: SubscriptionConfiguration) async throws
    func receive(_ transaction: VerifiedStoreTransaction) async throws -> SubscriptionAcknowledgement
}

struct UnconfiguredSubscriptionReceiver: SubscriptionTransactionReceiver {
    let configured = false
    func preparePurchase(configuration: SubscriptionConfiguration) async throws {
        throw SubscriptionError.serverUnavailable
    }
    func receive(_ transaction: VerifiedStoreTransaction) async throws -> SubscriptionAcknowledgement {
        throw SubscriptionError.serverUnavailable
    }
}
