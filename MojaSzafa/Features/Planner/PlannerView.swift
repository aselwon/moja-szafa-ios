import SwiftUI

struct PlannerView: View {
    @ObservedObject var model: PlannerModel
    let outfits: any OutfitRepository
    let wardrobe: any WardrobeRepository
    @State private var week = Date()
    @State private var creating = false
    @State private var moving: PlannedOutfit?
    @State private var confirming: PlannedOutfit?
    private var through: Date { Calendar.current.date(byAdding: .day, value: 6, to: week) ?? week }

    var body: some View {
        List {
            Section {
                Text("planner.separate").font(.callout)
                DatePicker("planner.week", selection: $week, displayedComponents: .date)
            }
            if model.loading { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await reload() } }
            }
            if model.pending != nil {
                Text("planner.pending")
                Button("planner.retryMutation") { Task { await model.retry() } }.disabled(model.saving)
            }
            if model.undo != nil && model.pending == nil {
                Button("planner.undo") { Task { await model.undoLast() } }.disabled(model.saving)
            }
            if model.items.isEmpty && !model.loading && model.errorKey == nil { Text("planner.empty") }
            if model.nextCursor != nil {
                Button("wardrobe.more") { Task { await model.load(from: PlannerDay.string(week), through: PlannerDay.string(through), more: true) } }
                    .disabled(model.loading || model.saving)
            }
            ForEach(model.items) { plan in
                Section {
                    Text(verbatim: plan.outfit.name).font(.headline)
                    Text(verbatim: "\(plan.day) · \(plan.timezone)").font(.caption)
                    OutfitCollage(garments: plan.outfit.garments, repository: wardrobe)
                    if plan.wearID != nil { Label("planner.confirmed", systemImage: "checkmark.circle") }
                    Button("planner.move") { moving = plan }
                    Button("planner.delete", role: .destructive) {
                        Task { _ = await model.change(PlannerMutation(action: .delete, id: plan.id, baseVersion: plan.version)) }
                    }
                    Button("planner.confirm") { confirming = plan }.disabled(!plan.canConfirm)
                }.disabled(model.saving || model.pending != nil)
            }
        }
        .navigationTitle("planner.title")
        .toolbar { Button("planner.new") { creating = true }.disabled(model.saving || model.pending != nil) }
        .task(id: PlannerDay.string(week)) { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $creating) {
            NavigationStack { PlanEditor(model: model, outfits: outfits, plan: nil) }
        }
        .sheet(item: $moving) { plan in
            NavigationStack { PlanEditor(model: model, outfits: outfits, plan: plan) }
        }
        .confirmationDialog("planner.confirmTitle", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let plan = confirming {
                Button("planner.confirm") {
                    Task { _ = await model.change(PlannerMutation(action: .confirm, id: plan.id, baseVersion: plan.version, outfitVersion: plan.outfit.version)) }
                }
            }
        } message: {
            Text("planner.confirmMessage")
            if let plan = confirming { Text(verbatim: "\(plan.day) · \(plan.timezone)") }
        }
    }
    private func reload() async {
        await model.load(from: PlannerDay.string(week), through: PlannerDay.string(through))
    }
}

private struct PlanEditor: View {
    @ObservedObject var model: PlannerModel
    @StateObject private var picker: OutfitsModel
    let plan: PlannedOutfit?
    @State private var selected: UUID?
    @State private var day = Date()
    @Environment(\.dismiss) private var dismiss
    init(model: PlannerModel, outfits: any OutfitRepository, plan: PlannedOutfit?) {
        self.model = model; self.plan = plan
        _picker = StateObject(wrappedValue: OutfitsModel(repository: outfits))
    }
    var body: some View {
        List {
            Text("planner.separate")
            DatePicker("planner.day", selection: $day, in: Date()..., displayedComponents: .date)
            Text(verbatim: TimeZone.current.identifier).font(.caption)
            if plan == nil {
                if picker.loading { ProgressView("common.loading") }
                if let key = picker.errorKey {
                    Text(LocalizedStringKey(key))
                    Button("common.retry") { Task { await picker.load() } }
                }
                if picker.items.isEmpty && !picker.loading && picker.errorKey == nil { Text("planner.noOutfits") }
                ForEach(picker.items) { outfit in
                    Button { selected = outfit.id } label: {
                        HStack {
                            Text(verbatim: outfit.name)
                            if selected == outfit.id { Image(systemName: "checkmark") }
                        }
                    }.accessibilityAddTraits(selected == outfit.id ? .isSelected : [])
                }
                if picker.nextCursor != nil { Button("wardrobe.more") { Task { await picker.load(more: true) } } }
            }
            if let key = model.errorKey { Text(LocalizedStringKey(key)) }
            if let pending = model.pending {
                Text("planner.pending")
                Button("planner.retryMutation") {
                    Task { if await model.change(pending) { dismiss() } }
                }.disabled(model.saving)
            }
            Button("planner.save") {
                Task {
                    let request = PlannerMutation(action: plan == nil ? .create : .move,
                        id: plan?.id ?? UUID(), baseVersion: plan?.version ?? 0,
                        outfitID: plan == nil ? selected : nil, day: PlannerDay.string(day), timezone: TimeZone.current.identifier)
                    if await model.change(request) { dismiss() }
                }
            }.disabled((plan == nil && selected == nil) || model.saving || model.pending != nil)
        }
        .navigationTitle("planner.title")
        .toolbar { Button("outfits.cancel") { dismiss() }.disabled(model.saving) }
        .interactiveDismissDisabled(model.saving)
        .task { if plan == nil { await picker.load() } }
    }
}
