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
struct SubscriptionLegalLinks: Sendable, Equatable {
    let privacy: URL
    let terms: URL
    init?(privacy: String?, terms: String?) {
        func validated(_ value: String?) -> URL? {
            guard let value, let parts = URLComponents(string: value), parts.scheme == "https",
                  let host = parts.host, !host.isEmpty, host != "localhost", host != "127.0.0.1",
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.port == nil || parts.port == 443 else { return nil }
            return parts.url
        }
        guard let privacy = validated(privacy), let terms = validated(terms) else { return nil }
        self.privacy = privacy; self.terms = terms
    }
    static func configured(bundle: Bundle = .main) -> Self? {
        Self(privacy: bundle.object(forInfoDictionaryKey: "SubscriptionPrivacyURL") as? String,
             terms: bundle.object(forInfoDictionaryKey: "SubscriptionTermsURL") as? String)
    }
}

struct SubscriptionIntroductoryOffer: Sendable, Equatable {
    enum Mode: Sendable, Equatable { case freeTrial, payAsYouGo, payUpFront }
    enum Unit: String, Sendable { case day, week, month, year }
    let mode: Mode
    let displayPrice: String
    let unit: Unit
    let value: Int
    let periodCount: Int

    init?(mode: Mode, displayPrice: String, unit: Unit, value: Int, periodCount: Int) {
        guard !displayPrice.isEmpty, (1...366).contains(value), (1...100).contains(periodCount),
              mode == .payAsYouGo || periodCount == 1 else { return nil }
        self.mode = mode; self.displayPrice = displayPrice; self.unit = unit
        self.value = value; self.periodCount = periodCount
    }

    func periodDescription(locale: Locale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian); calendar.locale = locale
        formatter.calendar = calendar; formatter.unitsStyle = .full; formatter.maximumUnitCount = 1
        var components = DateComponents()
        switch unit {
        case .day: formatter.allowedUnits = [.day]; components.day = value
        case .week: formatter.allowedUnits = [.weekOfMonth]; components.weekOfMonth = value
        case .month: formatter.allowedUnits = [.month]; components.month = value
        case .year: formatter.allowedUnits = [.year]; components.year = value
        }
        return formatter.string(from: components) ?? "\(value) \(unit.rawValue)"
    }
}

struct SubscriptionProduct: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// Localized by StoreKit. Never reconstruct a price from fixture values.
    let displayPrice: String
    let period: SubscriptionPeriod
    let groupID: String
    let introductoryOffer: SubscriptionIntroductoryOffer?

    init(id: String, name: String, displayPrice: String, period: SubscriptionPeriod, groupID: String,
         introductoryOffer: SubscriptionIntroductoryOffer? = nil) {
        self.id = id; self.name = name; self.displayPrice = displayPrice
        self.period = period; self.groupID = groupID; self.introductoryOffer = introductoryOffer
    }
}

/// Presentation only. The server, never this model or the device clock, grants access.
struct SubscriptionEntitlement: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable { case active, gracePeriod = "grace_period", billingRetry = "billing_retry", expired, revoked }
    let productID: String
    let originalTransactionID: String
    let environment: String
    let expiresAt: Date
    let graceExpiresAt: Date?
    let status: Status
    var id: String { environment + ":" + originalTransactionID }
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
    func entitlements(configuration: SubscriptionConfiguration) async throws -> [SubscriptionEntitlement]
}

extension SubscriptionTransactionReceiver {
    func entitlements(configuration: SubscriptionConfiguration) async throws -> [SubscriptionEntitlement] {
        throw SubscriptionError.serverUnavailable
    }
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
