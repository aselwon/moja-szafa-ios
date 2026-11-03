import SwiftUI

struct TodayView: View {
    var store: OfflineStore? = nil
    @State private var state: OfflineStore.State?
    @State private var editing: SyncWear?
    @State private var errorKey: String?
    @State private var loading = false

    var body: some View {
        List {
            if loading { ProgressView("common.loading") }
            if store == nil { Text("foundation.serviceUnavailable") }
            if let errorKey { Text(LocalizedStringKey(errorKey)) }
            if let state {
                if !state.outbox.isEmpty { Text("wear.pending") }
                if state.wears.filter({ !$0.deleted }).isEmpty { Text("wear.historyEmpty") }
                ForEach(state.outbox.filter { $0.wear != nil && ["version_conflict", "validation_failed"].contains($0.failure ?? "") }, id: \.id) { pending in
                    if let wear = pending.wear?.wear {
                        Text("wear.conflict")
                        Button("wear.discardLocal") { Task { await resolve(wear.id, keepLocal: false) } }
                        if pending.failure == "version_conflict" {
                            Button("wear.keepLocal") { Task { await resolve(wear.id, keepLocal: true) } }
                                .disabled(state.wears.first(where: { $0.id == wear.id })?.deleted == true)
                        }
                    }
                }
                ForEach(state.wears.filter { !$0.deleted }.sorted { $0.wornOn > $1.wornOn }) { wear in
                    Button { editing = wear } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: wear.wornOn).font(.headline)
                            Text(verbatim: wear.timezone).font(.caption)
                            Text(verbatim: wear.garmentIDs.compactMap { id in
                                state.garments.first { $0.id == id }?.fields.name
                            }.joined(separator: ", "))
                        }
                    }
                }
            }
            Button("common.retry") { Task { await reload() } }.disabled(loading || store == nil)
        }
        .navigationTitle("tab.today")
        .toolbar {
            Button("wear.new") { editing = WearEditor.newWear() }.disabled(store == nil || loading)
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { wear in
            if let store { NavigationStack { WearEditor(wear: wear, store: store) } }
        }
    }

    @MainActor private func reload() async {
        guard let store else { return }
        loading = true; errorKey = nil
        defer { loading = false }
        do { try await store.synchronize() }
        catch { errorKey = error is URLError ? "wear.offline" : "wear.syncFailed" }
        state = await store.status()
    }

    @MainActor private func resolve(_ id: UUID, keepLocal: Bool) async {
        do { try await store?.resolveWear(id: id, keepLocal: keepLocal); await reload() }
        catch { errorKey = "wear.syncFailed" }
    }
}

/// DATE is edited as a calendar-day string, never converted through the phone's
/// current timezone when an existing event is opened after travel.
struct WearEditor: View {
    let wear: SyncWear
    let store: OfflineStore
    @State private var wornOn: String
    @State private var selected: Set<UUID>
    @State private var garments: [SyncGarment] = []
    @State private var saving = false
    @State private var errorKey: String?
    @Environment(\.dismiss) private var dismiss

    init(wear: SyncWear, store: OfflineStore) {
        self.wear = wear; self.store = store
        _wornOn = State(initialValue: wear.wornOn)
        _selected = State(initialValue: Set(wear.garmentIDs))
    }

    static func newWear(garmentIDs: [UUID] = []) -> SyncWear {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return SyncWear(id: UUID(), version: 0, deleted: false, wornOn: formatter.string(from: Date()),
                        timezone: TimeZone.current.identifier, garmentIDs: garmentIDs)
    }

    var body: some View {
        Form {
            TextField("wear.date", text: $wornOn).autocorrectionDisabled()
            Text(verbatim: wear.timezone).font(.caption)
            Text("wear.snapshotExplanation")
            Section("outfits.choose") {
                ForEach(selected.filter { id in !garments.contains(where: { $0.id == id }) }.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                    Button("wear.removeMissing") { selected.remove(id) }
                }
                ForEach(garments, id: \.id) { garment in
                    Toggle(isOn: Binding(get: { selected.contains(garment.id) }, set: { enabled in
                        if enabled { selected.insert(garment.id) } else { selected.remove(garment.id) }
                    })) { Text(verbatim: garment.fields.name) }
                }
            }
            if let errorKey { Text(LocalizedStringKey(errorKey)) }
            Button("common.save") { Task { await save() } }.disabled(selected.isEmpty || saving)
            if saving { ProgressView("common.loading") }
        }
        .disabled(saving)
        .navigationTitle("wear.edit")
        .toolbar { Button("common.cancel") { dismiss() }.disabled(saving) }
        .interactiveDismissDisabled(saving)
        .task {
            // Cached data remains editable when the network is unavailable.
            try? await store.synchronize()
            garments = await store.status().garments.filter { !$0.deleted }
        }
    }

    @MainActor private func save() async {
        saving = true; errorKey = nil
        defer { saving = false }
        let ids = selected.sorted { $0.uuidString < $1.uuidString }
        do {
            let state = await store.status()
            if state.wears.contains(where: { $0.id == wear.id }) {
                try await store.editWear(SyncWear(id: wear.id, version: wear.version, deleted: false,
                    wornOn: wornOn, timezone: wear.timezone, garmentIDs: ids))
            } else {
                guard wear.version == 0 else { throw OfflineError.conflict }
                try await store.recordWear(id: wear.id, wornOn: wornOn, timezone: wear.timezone, garmentIDs: ids)
            }
            dismiss()
        } catch {
            errorKey = error as? APIClientError == .invalidRequest ? "wear.invalid" : "wear.saveFailed"
        }
    }
}
