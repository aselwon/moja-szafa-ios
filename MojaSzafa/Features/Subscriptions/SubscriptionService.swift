import Foundation
import CryptoKit

/// Coordinates verified StoreKit events with the authoritative server. This
/// service deliberately has no `isPlus` switch: client state cannot unlock AI.
actor SubscriptionService {
    enum PurchaseStatus: Sendable, Equatable { case accepted, pending, cancelled }
    private let configuration: SubscriptionConfiguration
    private let accountID: UUID
    private let storefront: any SubscriptionStorefront
    private let receiver: any SubscriptionTransactionReceiver
    private var active = true
    private var busy = false
    private var starting = false
    private var listener: Task<Void, Never>?
    private var inFlight: [String: Task<SubscriptionAcknowledgement, Error>] = [:]
    private(set) var lastDeliveryFailed = false

    init(configuration: SubscriptionConfiguration, accountID: UUID,
         storefront: any SubscriptionStorefront, receiver: any SubscriptionTransactionReceiver) {
        self.configuration = configuration; self.accountID = accountID
        self.storefront = storefront; self.receiver = receiver
    }

    func products() async throws -> [SubscriptionProduct] {
        try requireReady()
        try await receiver.preparePurchase(configuration: configuration)
        try requireReady()
        let products = try await storefront.products()
        try requireReady()
        guard products.count == 2, Set(products.map(\.id)) == configuration.productIDs,
              Set(products.map(\.groupID)).count == 1,
              products.first(where: { $0.id == configuration.monthlyID })?.period == .month,
              products.first(where: { $0.id == configuration.yearlyID })?.period == .year else {
            throw SubscriptionError.invalidProducts
        }
        return products
    }

    func start() async {
        guard active, receiver.configured, listener == nil, !starting else { return }
        starting = true; defer { starting = false }
        let stream = await storefront.updates()
        guard active else { return }
        listener = Task { [weak self] in
            for await transaction in stream {
                guard !Task.isCancelled, let self else { break }
                do { try await self.deliver(transaction) }
                catch { await self.deliveryFailed() }
            }
        }
        await retryUnfinished()
    }

    func purchase(productID: String) async throws -> PurchaseStatus {
        try requireReady()
        guard !busy else { throw SubscriptionError.busy }
        guard configuration.productIDs.contains(productID) else { throw SubscriptionError.invalidProducts }
        busy = true; defer { busy = false }
        try await receiver.preparePurchase(configuration: configuration)
        try requireReady()
        try Task.checkCancellation()
        let result = try await storefront.purchase(productID: productID)
        try requireReady()
        switch result {
        case .pending: return .pending
        case .cancelled: return .cancelled
        case .verified(let transaction):
            do { try await deliver(transaction); return .accepted }
            catch { lastDeliveryFailed = true; throw error }
        }
    }

    /// Explicit user intent only. AppStore.sync may prompt for Apple credentials.
    func restore() async throws {
        try requireReady()
        guard !busy else { throw SubscriptionError.busy }
        busy = true; defer { busy = false }
        try await storefront.synchronize()
        try requireReady()
        let receipts = await storefront.currentTransactions()
        try requireReady()
        for transaction in receipts { try await deliver(transaction) }
        await retryUnfinished()
        if lastDeliveryFailed { throw SubscriptionError.serverUnavailable }
    }

    func retryUnfinished() async {
        guard active, receiver.configured else { return }
        let receipts = await storefront.unfinishedTransactions()
        guard active else { return }
        lastDeliveryFailed = false
        for transaction in receipts {
            if Task.isCancelled { return }
            do { try await deliver(transaction) }
            catch { lastDeliveryFailed = true }
        }
    }

    func stop() {
        active = false
        listener?.cancel(); listener = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func deliver(_ transaction: VerifiedStoreTransaction) async throws {
        try requireReady()
        guard transaction.accountToken == accountID else { throw SubscriptionError.accountMismatch }
        guard transaction.id > 0, transaction.originalID > 0,
              configuration.productIDs.contains(transaction.productID),
              !transaction.signedRepresentation.isEmpty,
              transaction.signedRepresentation.utf8.count <= 100_000 else { throw SubscriptionError.unverified }
        // Same ID can acquire a new signed revocation/refund state. Coalesce only
        // identical in-flight receipts, never permanently suppress updates by ID.
        let key = SHA256.hash(data: Data(transaction.signedRepresentation.utf8)).map { String(format: "%02x", $0) }.joined()
        let task: Task<SubscriptionAcknowledgement, Error>
        if let existing = inFlight[key] { task = existing }
        else {
            let receiver = receiver
            task = Task { try await receiver.receive(transaction) }
            inFlight[key] = task
        }
        defer { inFlight.removeValue(forKey: key) }
        let acknowledgement = try await task.value
        try requireReady()
        try Task.checkCancellation()
        guard acknowledgement.transactionID == transaction.id else { throw SubscriptionError.invalidAcknowledgement }
        await storefront.finish(transactionID: transaction.id)
    }

    private func deliveryFailed() { if active { lastDeliveryFailed = true } }
    private func requireReady() throws {
        guard active else { throw SubscriptionError.inactive }
        guard receiver.configured else { throw SubscriptionError.serverUnavailable }
    }
}
