import SwiftUI
import StoreKit

/// Prices and eligible introductory offers come from StoreKit. Status comes
/// from the authoritative server; this screen cannot unlock application data.
struct SubscriptionPurchaseView: View {
    let service: SubscriptionService?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var products: [SubscriptionProduct] = []
    @State private var entitlements: [SubscriptionEntitlement] = []
    @State private var statusAvailable = false
    @State private var showManagement = false
    @State private var busy = false
    @State private var message = "subscriptions.unavailable"

    var body: some View {
        Form {
            Section { Text(LocalizedStringKey(message)) }
            Section("subscriptions.currentPlan") {
                if !statusAvailable { Text("subscriptions.statusUnavailable") }
                else if entitlements.isEmpty { Text("subscriptions.statusEmpty") }
                ForEach(entitlements) { entitlement in
                    VStack(alignment: .leading, spacing: 8) {
                        if let product = products.first(where: { $0.id == entitlement.productID }) { Text(product.name).font(.headline) }
                        Text(LocalizedStringKey("subscriptions.status." + entitlement.status.rawValue))
                        LabeledContent("subscriptions.expires", value: entitlement.expiresAt.formatted(date: .abbreviated, time: .omitted))
                        if let grace = entitlement.graceExpiresAt {
                            LabeledContent("subscriptions.graceExpires", value: grace.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            ForEach(products) { product in
                Section {
                    Text(product.name).font(.headline)
                    LabeledContent(product.period == .month ? "subscriptions.monthly" : "subscriptions.yearly",
                                   value: product.displayPrice)
                    if let intro = product.introductoryOffer {
                        switch intro.mode {
                        case .freeTrial:
                            Text("subscriptions.offer.freeTrial \(intro.periodDescription(locale: locale))")
                        case .payUpFront:
                            Text("subscriptions.offer.upfront \(intro.displayPrice) \(intro.periodDescription(locale: locale))")
                        case .payAsYouGo:
                            Text("subscriptions.offer.payAsYouGo \(intro.displayPrice) \(intro.periodDescription(locale: locale)) \(intro.periodCount)")
                        }
                    }
                    if product.period == .month { Text("subscriptions.renewal.month \(product.displayPrice)") }
                    else { Text("subscriptions.renewal.year \(product.displayPrice)") }
                    Button("subscriptions.purchase") { Task { await purchase(product.id) } }
                        .disabled(busy || service?.legalLinks == nil)
                }
            }
            Section {
                Text("subscriptions.renewalDisclosure")
                Text("subscriptions.dataRetained")
                if let links = service?.legalLinks {
                    Link("subscriptions.privacy", destination: links.privacy)
                    Link("subscriptions.terms", destination: links.terms)
                }
                Button("subscriptions.manage") { showManagement = true }.disabled(busy)
            }
            if service != nil {
                Section {
                    Button("subscriptions.restore") { Task { await restore() } }.disabled(busy)
                    Button("profile.retry") { Task { await load() } }.disabled(busy)
                }
            }
            if busy { ProgressView() }
        }.navigationTitle("subscriptions.title")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("subscriptions.close") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $showManagement)
            .onChange(of: showManagement) { _, visible in
                if !visible { Task { await refreshStatus() } }
            }
            .task { await load() }
    }

    private func load() async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do {
            await service.start()
            products = try await service.products()
            message = service.legalLinks == nil ? "subscriptions.legalMissing" : "subscriptions.storePrices"
        } catch { products = []; message = "subscriptions.unavailable" }
        await refreshStatus()
    }
    private func refreshStatus() async {
        guard let service else { return }
        do { entitlements = try await service.entitlements().sorted { $0.expiresAt > $1.expiresAt }; statusAvailable = true }
        catch { entitlements = []; statusAvailable = false }
    }
    private func purchase(_ id: String) async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do {
            switch try await service.purchase(productID: id) {
            case .accepted: message = "subscriptions.accepted"; await refreshStatus()
            case .pending: message = "subscriptions.pending"
            case .cancelled: message = "subscriptions.cancelled"
            }
        } catch { message = "subscriptions.unconfirmed" }
    }
    private func restore() async {
        guard let service else { return }
        busy = true; defer { busy = false }
        do { try await service.restore(); message = "subscriptions.restored"; await refreshStatus() }
        catch { message = "subscriptions.unconfirmed" }
    }
}
