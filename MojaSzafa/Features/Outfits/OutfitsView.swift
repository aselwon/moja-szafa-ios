import SwiftUI

struct OutfitsView: View {
    @StateObject private var model: OutfitsModel
    @ObservedObject private var personalization: PersonalizationModel
    @State private var showingPreferences = false
    @State private var feedbackOutfit: Outfit?
    let wardrobe: any WardrobeRepository
    let wearStore: OfflineStore?
    @State private var recording: SyncWear?
    @State private var editing: Outfit?
    @State private var favoritesOnly = false

    init(repository: any OutfitRepository, wardrobe: any WardrobeRepository, wearStore: OfflineStore? = nil, personalization: PersonalizationModel? = nil) {
        _model = StateObject(wrappedValue: OutfitsModel(repository: repository))
        self.personalization = personalization ?? PersonalizationModel(repository: repository)
        self.wearStore = wearStore
        self.wardrobe = wardrobe
    }

    var body: some View {
        List {
            Toggle("outfits.favoritesOnly", isOn: $favoritesOnly)
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await model.load() } }
            }
            if model.loading { ProgressView("common.loading") }
            if model.items.isEmpty && !model.loading && model.errorKey == nil { Text("outfits.empty") }
            ForEach(model.items.filter { !favoritesOnly || $0.favorite }) { outfit in
                Button { editing = model.pendingDraft ?? outfit } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: outfit.name).font(.headline)
                        if outfit.favorite { Label("outfits.favorite", systemImage: "heart.fill") }
                        OutfitCollage(garments: outfit.garments, repository: wardrobe)
                    }
                }.buttonStyle(.plain)
                Button("personalization.feedback") { feedbackOutfit = outfit }
                if wearStore != nil {
                    Button("wear.today") { recording = WearEditor.newWear(garmentIDs: outfit.garments.map(\.id)) }
                }
            }
            if model.nextCursor != nil {
                Button("wardrobe.more") { Task { await model.load(more: true) } }.disabled(model.loading)
            }
        }
        .navigationTitle("tab.outfits")
        .toolbar {
            Button("outfits.new") { editing = model.pendingDraft ?? Outfit() }
            Button("personalization.title") { showingPreferences = true }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showingPreferences) {
            NavigationStack { PersonalizationEditor(model: personalization, outfit: nil) }
        }
        .sheet(item: $feedbackOutfit) { outfit in
            NavigationStack { PersonalizationEditor(model: personalization, outfit: outfit) }
        }
        .sheet(item: $recording) { wear in
            if let wearStore { NavigationStack { WearEditor(wear: wear, store: wearStore) } }
        }
        .sheet(item: $editing) { outfit in
            NavigationStack { OutfitEditor(outfit: outfit, model: model, wardrobe: wardrobe) }
        }
    }
}

struct OutfitCollage: View {
    let garments: [Garment]
    let repository: any WardrobeRepository
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 120))]) {
            ForEach(garments) { garment in
                VStack(alignment: .leading) {
                    WardrobeThumbnail(imageID: garment.imageID, repository: repository)
                    Text(verbatim: garment.name)
                    if garment.archived {
                        Label("outfits.archived", systemImage: "exclamationmark.triangle").foregroundStyle(Color("warning"))
                    }
                }
            }
        }
    }
}

private struct OutfitEditor: View {
    @State var outfit: Outfit
    @State private var exporting: Outfit?
    @ObservedObject var model: OutfitsModel
    @StateObject private var picker: WardrobeModel
    let wardrobe: any WardrobeRepository
    @Environment(\.dismiss) private var dismiss

    init(outfit: Outfit, model: OutfitsModel, wardrobe: any WardrobeRepository) {
        _outfit = State(initialValue: outfit)
        self.model = model; self.wardrobe = wardrobe
        _picker = StateObject(wrappedValue: WardrobeModel(repository: wardrobe))
    }

    var body: some View {
        List {
            Section {
                TextField("outfits.name", text: $outfit.name)
                Toggle("outfits.favorite", isOn: $outfit.favorite)
                Text("outfits.history").font(.caption)
                OutfitCollage(garments: outfit.garments, repository: wardrobe)
                ForEach(outfit.garments) { garment in
                    Button { outfit.garments.removeAll { $0.id == garment.id } } label: {
                        Label { Text(verbatim: garment.name) } icon: { Image(systemName: "minus.circle") }
                    }.accessibilityHint(Text("outfits.remove"))
                }
            }.disabled(model.pending != nil || model.saving)
            Section {
                Button("outfits.export.title", systemImage: "square.and.arrow.up") { exporting = outfit }
                    .disabled(outfit.garments.isEmpty)
            }
            Section("outfits.choose") {
                TextField("wardrobe.search", text: $picker.query.search)
                Toggle("wardrobe.archived", isOn: $picker.query.archived)
                if picker.state == .loading { ProgressView("common.loading") }
                if picker.state == .empty { Text("wardrobe.noResults") }
                if picker.state == .failed || picker.state == .offline || picker.state == .backendNotConfigured {
                    Text("wardrobe.detailFailed")
                    Button("common.retry") { Task { await picker.reload() } }
                }
                ForEach(picker.items) { garment in
                    Button { toggle(garment) } label: {
                        HStack {
                            Text(verbatim: garment.name)
                            if garment.archived { Label("outfits.archived", systemImage: "exclamationmark.triangle") }
                            if outfit.garments.contains(where: { $0.id == garment.id }) { Image(systemName: "checkmark") }
                        }
                    }.accessibilityAddTraits(outfit.garments.contains(where: { $0.id == garment.id }) ? .isSelected : [])
                }
                if picker.pageFailed { Text("foundation.loadFailed") }
                if picker.nextOffset != nil {
                    Button("wardrobe.more") { Task { await picker.loadMore() } }.disabled(picker.loadingMore)
                }
            }.disabled(model.pending != nil || model.saving)
            if let key = model.errorKey { Text(LocalizedStringKey(key)) }
            if model.pending != nil { Text("outfits.pending") }
            Button {
                Task { if await model.save(outfit) { dismiss() } }
            } label: { Text(LocalizedStringKey(model.pending == nil ? "outfits.save" : "common.retry")) }
            .disabled(!outfit.isValid || model.saving)
            if model.saving { ProgressView("common.loading") }
        }
        .navigationTitle("outfits.edit")
        .toolbar { Button("outfits.cancel") { dismiss() }.disabled(model.saving) }
        .interactiveDismissDisabled(model.saving)
        .task(id: picker.query) { await picker.reload() }
        .sheet(item: $exporting) { selected in
            OutfitExportView(outfit: selected, repository: wardrobe)
        }
    }

    private func toggle(_ garment: Garment) {
        if outfit.garments.contains(where: { $0.id == garment.id }) { outfit.garments.removeAll { $0.id == garment.id } }
        else if outfit.garments.count < 100 { outfit.garments.append(garment) }
    }
}


struct PersonalizationEditor: View {
    @ObservedObject var model: PersonalizationModel
    let outfit: Outfit?
    @Environment(\.dismiss) private var dismiss
    @State private var excluded: Set<String> = []
    @State private var colors: Set<String> = []
    @State private var rating = "like"
    @State private var reason = ""
    @State private var confirmingReset = false
    private let palette = ["black", "white", "gray", "beige", "brown", "red", "orange", "yellow", "green", "blue", "purple", "pink", "other"]

    var body: some View {
        Form {
            if let outfit {
                Section {
                    Text(verbatim: outfit.name)
                    Picker("personalization.rating", selection: $rating) {
                        Text("personalization.like").tag("like")
                        Text("personalization.dislike").tag("dislike")
                    }
                    TextField("personalization.reason", text: $reason, axis: .vertical)
                    Text("personalization.noWear").font(.caption)
                }.disabled(locked)
            } else {
                Section("personalization.exclusions") {
                    Text("personalization.hard").font(.caption)
                    ForEach(APIv1.Category.allCases, id: \.self) { category in
                        Toggle(LocalizedStringKey("garment.category." + category.rawValue), isOn: membership(category.rawValue, in: $excluded))
                    }
                }.disabled(locked)
                Section("personalization.colors") {
                    Text("personalization.soft").font(.caption)
                    ForEach(palette, id: \.self) { color in
                        Toggle(LocalizedStringKey("garment.color." + color), isOn: membership(color, in: $colors))
                    }
                }.disabled(locked)
            }
            if let key = model.errorKey { Text(LocalizedStringKey(key)) }
            if model.busy { ProgressView("common.loading") }
            if model.pending != nil {
                Text("personalization.pending")
                Button("common.retry") { Task { if await model.retry() { hydrate() } } }.disabled(model.busy)
            } else if model.state == nil {
                Button("common.retry") { Task { await model.load(outfitID: outfit?.id); hydrate() } }.disabled(model.busy)
            } else {
                Button("outfits.save") {
                    Task {
                        let saved: Bool
                        if outfit != nil {
                            saved = await model.save(action: .feedback, rating: rating, reason: reason)
                        } else {
                            saved = await model.save(action: .preferences, excluded: Array(excluded), colors: Array(colors))
                        }
                        if saved { dismiss() }
                    }
                }.disabled(locked || reason.unicodeScalars.count > 500)
                if outfit == nil {
                    Button("personalization.reset", role: .destructive) { confirmingReset = true }.disabled(locked)
                }
            }
        }
        .navigationTitle(LocalizedStringKey(outfit == nil ? "personalization.title" : "personalization.feedback"))
        .toolbar { Button("outfits.cancel") { dismiss() }.disabled(model.busy) }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("personalization.reset", isPresented: $confirmingReset) {
            Button("personalization.reset", role: .destructive) { Task { if await model.save(action: .reset) { hydrate() } } }
        } message: { Text("personalization.resetExplanation") }
        .task { await model.load(outfitID: outfit?.id); hydrate() }
    }
    private var locked: Bool { model.busy || model.pending != nil || model.state == nil }
    private func hydrate() {
        guard let state = model.state else { return }
        excluded = Set(state.excludedCategories); colors = Set(state.colors)
        rating = state.feedback?.rating ?? "like"; reason = state.feedback?.reason ?? ""
    }
    private func membership(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(value) }, set: { selected in
            if selected { values.wrappedValue.insert(value) } else { values.wrappedValue.remove(value) }
        })
    }
}
