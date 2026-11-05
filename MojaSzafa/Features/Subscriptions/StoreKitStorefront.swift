import Foundation
import StoreKit

actor StoreKitStorefront: SubscriptionStorefront {
    private let configuration: SubscriptionConfiguration
    private let accountID: UUID
    private var catalog: [String: Product] = [:]
    private var transactions: [UInt64: Transaction] = [:]

    init(configuration: SubscriptionConfiguration, accountID: UUID) {
        self.configuration = configuration; self.accountID = accountID
    }

    func products() async throws -> [SubscriptionProduct] {
        catalog.removeAll()
        let products = try await Product.products(for: configuration.productIDs)
        try Task.checkCancellation()
        guard products.count == 2, Set(products.map(\.id)) == configuration.productIDs else {
            throw SubscriptionError.invalidProducts
        }
        var result: [SubscriptionProduct] = []
        for product in products {
            guard product.type == .autoRenewable, let subscription = product.subscription,
                  subscription.subscriptionPeriod.value == 1, !subscription.subscriptionGroupID.isEmpty,
                  !product.displayPrice.isEmpty else { throw SubscriptionError.invalidProducts }
            let expected: SubscriptionPeriod = product.id == configuration.monthlyID ? .month : .year
            guard (expected == .month && subscription.subscriptionPeriod.unit == .month)
                    || (expected == .year && subscription.subscriptionPeriod.unit == .year) else {
                throw SubscriptionError.invalidProducts
            }
            var introductoryOffer: SubscriptionIntroductoryOffer?
            if let offer = subscription.introductoryOffer, await subscription.isEligibleForIntroOffer {
                let mode: SubscriptionIntroductoryOffer.Mode
                switch offer.paymentMode {
                case .freeTrial: mode = .freeTrial
                case .payAsYouGo: mode = .payAsYouGo
                case .payUpFront: mode = .payUpFront
                default: throw SubscriptionError.invalidProducts
                }
                let unit: SubscriptionIntroductoryOffer.Unit
                switch offer.period.unit {
                case .day: unit = .day
                case .week: unit = .week
                case .month: unit = .month
                case .year: unit = .year
                @unknown default: throw SubscriptionError.invalidProducts
                }
                introductoryOffer = SubscriptionIntroductoryOffer(mode: mode, displayPrice: offer.displayPrice,
                    unit: unit, value: offer.period.value, periodCount: offer.periodCount)
                guard introductoryOffer != nil else { throw SubscriptionError.invalidProducts }
            }
            result.append(SubscriptionProduct(id: product.id, name: product.displayName,
                displayPrice: product.displayPrice, period: expected, groupID: subscription.subscriptionGroupID,
                introductoryOffer: introductoryOffer))
        }
        guard Set(result.map(\.groupID)).count == 1 else { throw SubscriptionError.invalidProducts }
        catalog = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        return result.sorted { $0.period == .month && $1.period != .month }
    }

    func purchase(productID: String) async throws -> StorePurchaseResult {
        guard configuration.productIDs.contains(productID), let product = catalog[productID] else {
            throw SubscriptionError.unavailable
        }
        switch try await product.purchase(options: [.appAccountToken(accountID)]) {
        case .success(let verification): return .verified(try accept(verification))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw SubscriptionError.unavailable
        }
    }

    func synchronize() async throws { try await AppStore.sync() }

    func unfinishedTransactions() async -> [VerifiedStoreTransaction] {
        var values: [VerifiedStoreTransaction] = []
        for await verification in Transaction.unfinished {
            if Task.isCancelled { break }
            if let value = try? accept(verification) { values.append(value) }
        }
        return values
    }

    func currentTransactions() async -> [VerifiedStoreTransaction] {
        var values: [VerifiedStoreTransaction] = []
        for await verification in Transaction.currentEntitlements {
            if Task.isCancelled { break }
            if let value = try? accept(verification) { values.append(value) }
        }
        return values
    }

    func updates() async -> AsyncStream<VerifiedStoreTransaction> {
        let (stream, continuation) = AsyncStream<VerifiedStoreTransaction>.makeStream(bufferingPolicy: .bufferingOldest(100))
        let worker = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled, let self else { break }
                if let value = try? await self.accept(verification) { continuation.yield(value) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }

    func finish(transactionID: UInt64) async {
        guard let transaction = transactions.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    private func accept(_ verification: VerificationResult<Transaction>) throws -> VerifiedStoreTransaction {
        guard case .verified(let transaction) = verification else { throw SubscriptionError.unverified }
        guard transaction.productType == .autoRenewable, configuration.productIDs.contains(transaction.productID) else {
            throw SubscriptionError.invalidProducts
        }
        guard transaction.appAccountToken == accountID else { throw SubscriptionError.accountMismatch }
        // StoreKit retains unfinished transactions durably; this cache only holds
        // handles needed for finish(). Evicted handles can be restored by a scan.
        if transactions.count >= 200 { transactions.removeAll() }
        transactions[transaction.id] = transaction
        return VerifiedStoreTransaction(id: transaction.id, originalID: transaction.originalID,
            productID: transaction.productID, accountToken: transaction.appAccountToken,
            signedRepresentation: verification.jwsRepresentation)
    }
}
