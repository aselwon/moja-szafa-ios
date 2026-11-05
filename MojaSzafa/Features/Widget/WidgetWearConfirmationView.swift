import SwiftUI

/// A shortcut presents this flow; only the confirmation-dialog button writes wear.
struct WidgetWearConfirmationView: View {
    @ObservedObject var planner: PlannerModel
    @ObservedObject var personalization: PersonalizationModel
    let dependencies: AppDependencies
    @State private var confirming: PlannedOutfit?
    @State private var recorded = false
    private var day: String { PlannerDay.string(Date()) }

    var body: some View {
        List {
            Text("widget.confirmExplanation")
            if recorded { Label("planner.confirmed", systemImage: "checkmark.circle") }
            if planner.loading { ProgressView("common.loading") }
            if let key = planner.errorKey { Text(LocalizedStringKey(key)) }
            if planner.pending != nil {
                Text("planner.pending")
                Button("planner.retryMutation") { Task { await planner.retry() } }.disabled(planner.saving)
            }
            ForEach(planner.items.filter { !$0.deleted && $0.wearID == nil }) { plan in
                Button { confirming = plan } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: plan.outfit.name)
                        Text(verbatim: "\(plan.day) · \(plan.timezone)").font(.caption)
                        Text("planner.confirm")
                    }
                }.disabled(!plan.canConfirm || planner.saving || planner.pending != nil)
            }
            if planner.nextCursor != nil {
                Button("wardrobe.more") { Task { await planner.load(from: day, through: day, more: true) } }.disabled(planner.loading)
            }
            Button("widget.refresh") { Task { await planner.load(from: day, through: day) } }.disabled(planner.loading || planner.saving)
            NavigationLink("widget.chooseOutfit") {
                OutfitsView(repository: dependencies.outfits, wardrobe: dependencies.wardrobe,
                    wearStore: dependencies.wearStore ?? dependencies.offline, personalization: personalization)
            }
        }
        .navigationTitle("widget.confirmTitle")
        .task(id: day) { await planner.load(from: day, through: day) }
        .onReceive(NotificationCenter.default.publisher(for: WearIntentRoute.notification)) { _ in
            Task { await planner.load(from: day, through: day) }
        }
        .confirmationDialog("planner.confirmTitle", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let plan = confirming {
                Button("planner.confirm") {
                    Task {
                        recorded = await planner.change(PlannerMutation(action: .confirm, id: plan.id,
                            baseVersion: plan.version, outfitVersion: plan.outfit.version))
                    }
                }
            }
            Button("outfits.cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("planner.confirmMessage")
            if let plan = confirming { Text(verbatim: "\(plan.outfit.name) · \(plan.day) · \(plan.timezone)") }
        }
    }
}
