import XCTest
import StoreKitTest
@testable import MojaSzafa

@MainActor
final class SubscriptionStoreKitTests: XCTestCase {
    // CI runs this fixture setup in its own test-host process before the suite.
    // A fresh simulator can cache the sandbox purchase route at app launch,
    // before a test creates SKTestSession. Relaunching after provisioning lets
    // StoreKit select the local configuration before any purchase API is used.
    // This performs no purchase and does not replace the real purchase test.
    func testProvisionLocalStoreKitConfiguration() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestProducts", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        XCTAssertTrue(session.allTransactions().isEmpty)
    }

    func testRealLocalStoreKitProductsPurchaseVerificationAndRestoreScan() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestProducts", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let account = UUID()
        let configuration = try XCTUnwrap(SubscriptionConfiguration(monthlyID: "test.mojaszafa.plus.monthly", yearlyID: "test.mojaszafa.plus.yearly"))
        let store = StoreKitStorefront(configuration: configuration, accountID: account)
        let updates = await store.updates()
        let listener = Task { for await _ in updates { if Task.isCancelled { break } } }
        defer { listener.cancel() }
        let products = try await store.products()
        XCTAssertEqual(Set(products.map(\.id)), configuration.productIDs)
        XCTAssertEqual(Set(products.map(\.groupID)).count, 1)
        XCTAssertTrue(products.allSatisfy { !$0.displayPrice.isEmpty })
        guard case .verified(let receipt) = try await store.purchase(productID: configuration.monthlyID) else {
            return XCTFail("Expected a locally verified StoreKit transaction")
        }
        XCTAssertEqual(receipt.accountToken, account); XCTAssertFalse(receipt.signedRepresentation.isEmpty)
        let unfinished = await store.unfinishedTransactions(); XCTAssertTrue(unfinished.contains { $0.id == receipt.id })
        let current = await store.currentTransactions(); XCTAssertTrue(current.contains { $0.id == receipt.id })
        await store.finish(transactionID: receipt.id)
        let after = await store.unfinishedTransactions(); XCTAssertFalse(after.contains { $0.id == receipt.id })
    }
}
