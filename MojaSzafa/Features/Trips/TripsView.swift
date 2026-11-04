import SwiftUI

struct TripsView: View {
    @StateObject private var model: TripModel
    let outfits: any OutfitRepository
    let wardrobe: any WardrobeRepository
    @State private var creating = false
    init(repository: any TripRepository, outfits: any OutfitRepository, wardrobe: any WardrobeRepository, journalURL: URL?) {
        _model = StateObject(wrappedValue: TripModel(repository: repository, journalURL: journalURL))
        self.outfits = outfits; self.wardrobe = wardrobe
    }
    var body: some View {
        List {
            Text("trips.separate")
            TripStatus(model: model) { await model.loadList() }
            if model.items.isEmpty && !model.loading && model.errorKey == nil { Text("trips.empty") }
            ForEach(model.items) { trip in
                NavigationLink {
                    TripDetailView(model: model, id: trip.id, outfits: outfits, wardrobe: wardrobe)
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: trip.destination).font(.headline)
                        Text(verbatim: "\(trip.startsOn) – \(trip.endsOn)")
                    }
                }
            }
            if model.nextCursor != nil { Button("wardrobe.more") { Task { await model.loadList(more: true) } }.disabled(model.loading) }
        }
        .navigationTitle("trips.title")
        .toolbar { Button("trips.new") { creating = true }.disabled(model.saving || model.pending != nil) }
        .task { await model.loadList() }
        .refreshable { await model.loadList() }
        .sheet(isPresented: $creating, onDismiss: { Task { await model.loadList() } }) {
            NavigationStack { TripEditor(model: model, outfits: outfits, trip: nil) }
        }
    }
}

private struct TripStatus: View {
    @ObservedObject var model: TripModel
    let reload: () async -> Void
    var body: some View {
        if model.loading || model.saving { ProgressView("common.loading") }
        if let key = model.errorKey {
            Text(LocalizedStringKey(key))
            Button("common.retry") { Task { await reload() } }.disabled(model.saving)
        }
        if let pending = model.pending {
            Text("trips.pending")
            Button("trips.retry") { Task { _ = await model.change(pending) } }.disabled(model.saving)
        }
    }
}

private struct TripDetailView: View {
    @ObservedObject var model: TripModel
    let id: UUID
    let outfits: any OutfitRepository
    let wardrobe: any WardrobeRepository
    @State private var editing = false
    var body: some View {
        List {
            Text("trips.separate")
            TripStatus(model: model) { await model.load(id: id) }
            if let trip = model.current, trip.id == id {
                Section("trips.details") {
                    Text(verbatim: trip.destination).font(.headline)
                    Text(verbatim: "\(trip.startsOn) – \(trip.endsOn) · \(trip.timezone)")
                    Text(verbatim: trip.occasions.joined(separator: ", "))
                    Text("trips.count \(trip.packing.count) \(trip.maxItems)")
                    Button("trips.edit") { editing = true }.disabled(model.saving || model.pending != nil)
                }
                Section("trips.packing") {
                    if trip.packing.isEmpty { Text("trips.noItems") }
                    ForEach(trip.packing) { item in
                        VStack(alignment: .leading) {
                            Toggle(isOn: Binding(get: { item.packed }, set: { value in
                                Task { _ = await model.change(TripMutation(action: .pack, id: trip.id, baseVersion: trip.version, garmentID: item.id, packed: value)) }
                            })) { Text(verbatim: item.garment.name) }
                            .disabled(model.saving || model.pending != nil || (!item.available && !item.packed))
                            if !item.available { Text("trips.unavailable").foregroundStyle(Color("warning")) }
                        }
                    }
                    if let undo = model.undoPacking {
                        Button("trips.undoPacking") { Task { _ = await model.change(undo) } }.disabled(model.saving || model.pending != nil)
                    }
                }
                ForEach(trip.days) { day in
                    Section {
                        Text(verbatim: day.day).font(.headline)
                        if let name = day.outfitName { Text(verbatim: name) }
                        if day.repeated { Label("trips.repeat", systemImage: "repeat") }
                        if !day.unavailableIDs.isEmpty { Text("trips.changed").foregroundStyle(Color("warning")) }
                        OutfitCollage(garments: day.garments, repository: wardrobe)
                        if !day.missingCategories.isEmpty {
                            Text("trips.missing").font(.headline)
                            ForEach(day.missingCategories, id: \.self) { category in Text(LocalizedStringKey("trips.category.\(category)")) }
                        }
                    }
                }
            }
        }
        .navigationTitle("trips.title")
        .task(id: id) { await model.load(id: id) }
        .refreshable { await model.load(id: id) }
        .sheet(isPresented: $editing) {
            if let trip = model.current { NavigationStack { TripEditor(model: model, outfits: outfits, trip: trip) } }
        }
    }
}

private struct TripEditor: View {
    @ObservedObject var model: TripModel
    @StateObject private var picker: OutfitsModel
    let trip: TripPlan?
    @State private var destination: String
    @State private var occasions: String
    @State private var first: Date
    @State private var last: Date
    @State private var maximum: Int
    @State private var choices: [TripChoice]
    @State private var selectionDay: String?
    @Environment(\.dismiss) private var dismiss
    private var dateLabels: [String] { TripPlanner.days(from: PlannerDay.string(first), through: PlannerDay.string(last)) }
    private var selectedItems: Set<UUID> {
        Set(choices.flatMap { choice in picker.items.first(where: { $0.id == choice.outfitID })?.garments.map(\.id)
            ?? trip?.days.first(where: { $0.day == choice.day && $0.outfitID == choice.outfitID })?.garments.map(\.id) ?? [] })
    }
    init(model: TripModel, outfits: any OutfitRepository, trip: TripPlan?) {
        self.model = model; self.trip = trip
        _picker = StateObject(wrappedValue: OutfitsModel(repository: outfits))
        _destination = State(initialValue: trip?.destination ?? "")
        _occasions = State(initialValue: trip?.occasions.joined(separator: ", ") ?? "")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        _first = State(initialValue: trip.flatMap { formatter.date(from: $0.startsOn) } ?? Date())
        _last = State(initialValue: trip.flatMap { formatter.date(from: $0.endsOn) } ?? Date())
        _maximum = State(initialValue: trip?.maxItems ?? 10)
        _choices = State(initialValue: trip?.body.days ?? [])
    }
    var body: some View {
        List {
            Section("trips.details") {
                TextField("trips.destination", text: $destination)
                DatePicker("trips.start", selection: $first, displayedComponents: .date)
                DatePicker("trips.end", selection: $last, displayedComponents: .date)
                TextField("trips.occasions", text: $occasions)
                Stepper("trips.maximum \(maximum)", value: $maximum, in: 1...100)
                Text(verbatim: TimeZone.current.identifier).font(.caption)
                Text("trips.bounds").font(.caption)
                if dateLabels.isEmpty { Text("trips.invalidDates").foregroundStyle(Color("warning")) }
            }.disabled(model.saving || model.pending != nil)
            Section("trips.daily") {
                Text("trips.manual").font(.caption)
                if picker.loading { ProgressView("common.loading") }
                if let key = picker.errorKey {
                    Text(LocalizedStringKey(key))
                    Button("common.retry") { Task { await picker.load() } }
                }
                if picker.items.isEmpty && !picker.loading { Text("trips.noOutfits") }
                Button("trips.suggest") { choices = TripPlanner.suggest(days: dateLabels, outfits: picker.items, maxItems: maximum) }
                    .disabled(picker.items.isEmpty || dateLabels.isEmpty)
                if picker.nextCursor != nil {
                    Button("wardrobe.more") { Task { await picker.load(more: true) } }.disabled(picker.loading)
                }
                ForEach(choices) { choice in
                    Button { selectionDay = choice.day } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: choice.day)
                            if let name = picker.items.first(where: { $0.id == choice.outfitID })?.name
                                ?? trip?.days.first(where: { $0.outfitID == choice.outfitID && $0.day == choice.day })?.outfitName {
                                Text(verbatim: name)
                            } else { Text("trips.choose") }
                        }
                    }
                }
                Text("trips.count \(selectedItems.count) \(maximum)")
                if selectedItems.count > maximum { Text("trips.overLimit").foregroundStyle(Color("warning")) }
            }.disabled(model.saving || model.pending != nil)
            TripStatus(model: model) { await picker.load() }
            Button("trips.save") {
                let body = TripBody(destination: destination.trimmingCharacters(in: .whitespacesAndNewlines), startsOn: PlannerDay.string(first),
                    endsOn: PlannerDay.string(last), timezone: TimeZone.current.identifier,
                    occasions: occasions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, maxItems: maximum, days: choices)
                Task {
                    if await model.change(TripMutation(action: .save, id: trip?.id ?? UUID(), baseVersion: trip?.version ?? 0, trip: body)) { dismiss() }
                }
            }.disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || occasions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dateLabels.isEmpty || selectedItems.count > maximum || model.saving || model.pending != nil)
        }
        .navigationTitle("trips.title")
        .toolbar { Button("common.cancel") { dismiss() }.disabled(model.saving) }
        .interactiveDismissDisabled(model.saving)
        .task { reconcileDays(); await picker.load() }
        .onChange(of: dateLabels) { _, _ in reconcileDays() }
        .sheet(isPresented: Binding(get: { selectionDay != nil }, set: { if !$0 { selectionDay = nil } })) {
            NavigationStack {
                List {
                    Button("trips.leaveMissing") { select(nil) }
                    ForEach(picker.items.filter { $0.garments.allSatisfy { !$0.archived && $0.availability == .available } }) { outfit in
                        Button { select(outfit) } label: { Text(verbatim: outfit.name) }
                    }
                    if picker.nextCursor != nil { Button("wardrobe.more") { Task { await picker.load(more: true) } }.disabled(picker.loading) }
                }.navigationTitle("trips.choose")
                    .toolbar { Button("common.cancel") { selectionDay = nil } }
            }
        }
    }
    private func reconcileDays() {
        let previous = Dictionary(uniqueKeysWithValues: choices.map { ($0.day, $0) })
        choices = dateLabels.map { previous[$0] ?? TripChoice(day: $0) }
    }
    private func select(_ outfit: Outfit?) {
        if let index = choices.firstIndex(where: { $0.day == selectionDay }) {
            choices[index].outfitID = outfit?.id; choices[index].outfitVersion = outfit?.version
        }
        selectionDay = nil
    }
}
