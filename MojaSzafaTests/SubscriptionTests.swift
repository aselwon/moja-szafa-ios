import XCTest
@testable import MojaSzafa

private actor SubscriptionStoreFake: SubscriptionStorefront {
    var items: [SubscriptionProduct] = []
    var result: StorePurchaseResult = .pending
    var unfinished: [VerifiedStoreTransaction] = []
    var finished: [UInt64] = []
    var purchases = 0
    var restores = 0
    func setResult(_ value: StorePurchaseResult) { result = value }
    func setUnfinished(_ value: [VerifiedStoreTransaction]) { unfinished = value }
    func setProducts(_ value: [SubscriptionProduct]) { items = value }
    func products() async throws -> [SubscriptionProduct] { items }
    func purchase(productID: String) async throws -> StorePurchaseResult { purchases += 1; return result }
    func synchronize() async throws { restores += 1 }
    func unfinishedTransactions() async -> [VerifiedStoreTransaction] { unfinished }
    func currentTransactions() async -> [VerifiedStoreTransaction] { unfinished }
    func updates() async -> AsyncStream<VerifiedStoreTransaction> { AsyncStream { $0.finish() } }
    func finish(transactionID: UInt64) async { finished.append(transactionID); unfinished.removeAll { $0.id == transactionID } }
    func counts() -> ([UInt64], Int, Int) { (finished, purchases, restores) }
}

private actor SubscriptionReceiverFake: SubscriptionTransactionReceiver {
    nonisolated let configured: Bool
    var fail = false
    var preflightFails = false
    var wrongID = false
    var hold = false
    var received: [UInt64] = []
    var waiting: CheckedContinuation<SubscriptionAcknowledgement, Error>?
    init(configured: Bool = true) { self.configured = configured }
    func setPreflightFailure() { preflightFails = true }
    func preparePurchase(configuration: SubscriptionConfiguration) async throws {
        if preflightFails { throw SubscriptionError.serverUnavailable }
    }
    func configure(fail: Bool = false, wrongID: Bool = false, hold: Bool = false) {
        self.fail = fail; self.wrongID = wrongID; self.hold = hold
    }
    func receive(_ transaction: VerifiedStoreTransaction) async throws -> SubscriptionAcknowledgement {
        received.append(transaction.id)
        if fail { throw URLError(.notConnectedToInternet) }
        if hold { return try await withCheckedThrowingContinuation { waiting = $0 } }
        return SubscriptionAcknowledgement(transactionID: wrongID ? 999 : transaction.id)
    }
    func release(_ id: UInt64) { waiting?.resume(returning: SubscriptionAcknowledgement(transactionID: id)); waiting = nil }
    func isWaiting() -> Bool { waiting != nil }
    func count() -> Int { received.count }
}

@MainActor
final class SubscriptionTests: XCTestCase {
    private let account = UUID()
    private let configuration = SubscriptionConfiguration(monthlyID: "test.monthly", yearlyID: "test.yearly")!
    private func receipt(account: UUID? = nil) -> VerifiedStoreTransaction {
        VerifiedStoreTransaction(id: 7, originalID: 7, productID: "test.monthly", accountToken: account ?? self.account, signedRepresentation: "fixture-signed-representation")
    }
    private func service(_ store: SubscriptionStoreFake, _ receiver: SubscriptionReceiverFake) -> SubscriptionService {
        SubscriptionService(configuration: configuration, accountID: account, storefront: store, receiver: receiver)
    }
    func testAbsentOrInvalidConfigurationDoesNotInventProducts() {
        XCTAssertNil(SubscriptionConfiguration(monthlyID: nil, yearlyID: nil))
        XCTAssertNil(SubscriptionConfiguration(monthlyID: "$(MONTHLY)", yearlyID: "test.yearly"))
        XCTAssertNil(SubscriptionConfiguration(monthlyID: "same.product", yearlyID: "same.product"))
        XCTAssertEqual(configuration.productIDs, ["test.monthly", "test.yearly"])
    }
    func testUnconfiguredServerPreventsPurchaseSheetAndRestore() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake(configured: false)
        let service = service(store, receiver)
        do { _ = try await service.purchase(productID: "test.monthly"); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .serverUnavailable) }
        do { try await service.restore(); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .serverUnavailable) }
        let counts = await store.counts(); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0)
    }
    func testMismatchedSubscriptionGroupsAreRejected() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake()
        await store.setProducts([
            SubscriptionProduct(id: "test.monthly", name: "Monthly", displayPrice: "Localized monthly", period: .month, groupID: "one"),
            SubscriptionProduct(id: "test.yearly", name: "Yearly", displayPrice: "Localized yearly", period: .year, groupID: "two")])
        do { _ = try await service(store, receiver).products(); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidProducts) }
    }
    func testUnavailableServerPreflightPreventsPurchaseEvenWhenConfigured() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake()
        await receiver.setPreflightFailure()
        do { _ = try await service(store, receiver).purchase(productID: "test.monthly"); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .serverUnavailable) }
        let counts = await store.counts()
        XCTAssertEqual(counts.1, 0)
        XCTAssertTrue(counts.0.isEmpty)
    }
    func testPendingAndCancellationDoNotFinishOrSendUnverifiedReceipts() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake(), service = service(store, receiver)
        let pending = try await service.purchase(productID: "test.monthly"); XCTAssertEqual(pending, .pending)
        await store.setResult(.cancelled)
        let cancelled = try await service.purchase(productID: "test.monthly"); XCTAssertEqual(cancelled, .cancelled)
        let counts = await store.counts(); XCTAssertTrue(counts.0.isEmpty)
        let received = await receiver.count(); XCTAssertEqual(received, 0)
    }
    func testVerifiedPurchaseFinishesOnlyAfterMatchingServerAcknowledgement() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake()
        await store.setResult(.verified(receipt()))
        let result = try await service(store, receiver).purchase(productID: "test.monthly")
        XCTAssertEqual(result, .accepted)
        let counts = await store.counts(); XCTAssertEqual(counts.0, [7])
        let received = await receiver.count(); XCTAssertEqual(received, 1)
    }
    func testReceiptFromAnotherAccountNeverReachesServerOrFinishes() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake()
        await store.setResult(.verified(receipt(account: UUID())))
        do { _ = try await service(store, receiver).purchase(productID: "test.monthly"); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .accountMismatch) }
        let counts = await store.counts(); XCTAssertTrue(counts.0.isEmpty)
        let received = await receiver.count(); XCTAssertEqual(received, 0)
    }
    func testNetworkFailureLeavesAppleTransactionUnfinishedForExplicitRetry() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake(), service = service(store, receiver)
        await store.setResult(.verified(receipt())); await store.setUnfinished([receipt()]); await receiver.configure(fail: true)
        do { _ = try await service.purchase(productID: "test.monthly"); XCTFail() } catch {}
        let before = await store.counts(); XCTAssertTrue(before.0.isEmpty)
        await receiver.configure(); await service.retryUnfinished()
        let after = await store.counts(); XCTAssertEqual(after.0, [7])
        let received = await receiver.count(); XCTAssertEqual(received, 2)
    }
    func testMismatchedServerAcknowledgementDoesNotFinish() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake()
        await store.setResult(.verified(receipt())); await receiver.configure(wrongID: true)
        do { _ = try await service(store, receiver).purchase(productID: "test.monthly"); XCTFail() }
        catch { XCTAssertEqual(error as? SubscriptionError, .invalidAcknowledgement) }
        let counts = await store.counts(); XCTAssertTrue(counts.0.isEmpty)
    }
    func testLogoutFencesAReceiptAcknowledgementAlreadyInFlight() async throws {
        let store = SubscriptionStoreFake(), receiver = SubscriptionReceiverFake(), service = service(store, receiver)
        await store.setResult(.verified(receipt())); await receiver.configure(hold: true)
        let purchase = Task { try await service.purchase(productID: "test.monthly") }
        for _ in 0..<1000 {
            if await receiver.isWaiting() { break }
            await Task.yield()
        }
        let waiting = await receiver.isWaiting(); XCTAssertTrue(waiting)
        await service.stop(); await receiver.release(7)
        do { _ = try await purchase.value; XCTFail() } catch {}
        let counts = await store.counts(); XCTAssertTrue(counts.0.isEmpty)
    }
}
