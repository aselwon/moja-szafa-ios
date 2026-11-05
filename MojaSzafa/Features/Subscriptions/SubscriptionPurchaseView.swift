import SwiftUI

/// Purchase mechanics for T049. Marketing, entitlement-aware paywall placement,
/// published terms and configured trial disclosures are separate T051 work.
struct SubscriptionPurchaseView: View {
    let service: SubscriptionService?
    @State private var products: [SubscriptionProduct] = []
    @State private var busy = false
    @State private var message = "subscriptions.unavailable"

    var body: some View {
        Form {
            Section { Text(LocalizedStringKey(message)) }
            ForEach(products) { product in
                Section {
                    Text(product.name)
                    LabeledContent(product.period == .month ? "subscriptions.monthly" : "subscriptions.yearly",
                                   value: product.displayPrice)
                    Button("subscriptions.purchase") { Task { await purchase(product.id) } }.disabled(busy)
                }
            }
            if service != nil {
                Section {
                    Button("subscriptions.restore") { Task { await restore() } }.disabled(busy)
                    Button("profile.retry") { Task { await load() } }.disabled(busy)
                }
            }
            if busy { ProgressView() }
        }.navigationTitle("subscriptions.title").task { await load() }
    }

    private func load() async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do {
            await service.start()
            products = try await service.products()
            message = "subscriptions.storePrices"
        } catch { products = []; message = "subscriptions.unavailable" }
    }
    private func purchase(_ id: String) async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do {
            switch try await service.purchase(productID: id) {
            case .accepted: message = "subscriptions.accepted"
            case .pending: message = "subscriptions.pending"
            case .cancelled: message = "subscriptions.cancelled"
            }
        } catch { message = "subscriptions.unconfirmed" }
    }
    private func restore() async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do { try await service.restore(); message = "subscriptions.restored" }
        catch { message = "subscriptions.unconfirmed" }
    }
}
