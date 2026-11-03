import SwiftUI

struct OutfitsView: View {
    @StateObject private var model: OutfitsModel
    @State private var editing: Outfit?
    @State private var favoritesOnly = false

    init(repository: any OutfitRepository, wardrobe: any WardrobeRepository) {
        _model = StateObject(wrappedValue: OutfitsModel(repository: repository, wardrobe: wardrobe))
    }

    var body: some View {
        List {
            if model.loading { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Button("common.retry") { Task { await model.load() } }
            }
            if model.cached { Text("wardrobe.cached") }
            if let pending = model.pending {
                Button("outfits.resume") { editing = pending.outfit }
            }
            if model.loaded {
                Toggle("outfits.favoritesOnly", isOn: $favoritesOnly)
                if model.outfits.filter({ !favoritesOnly || $0.favorite }).isEmpty { Text("outfits.empty") }
                ForEach(model.outfits.filter { !favoritesOnly || $0.favorite }) { outfit in
                    Button { editing = model.pending?.outfit ?? outfit } label: {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(verbatim: outfit.name).font(.headline)
                                if outfit.favorite { Image(systemName: "heart.fill").accessibilityLabel(Text("outfits.favorite")) }
                            }
                            OutfitCollage(ids: outfit.garmentIDs, model: model)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("tab.outfits")
        .toolbar {
            Button("outfits.new", systemImage: "plus") { editing = Outfit() }
                .disabled(!model.loaded || model.loading || model.pending != nil)
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $editing) { draft in
            NavigationStack { OutfitEditor(model: model, draft: draft) }
        }
    }
}

private struct OutfitCollage: View {
    let ids: [UUID]
    @ObservedObject var model: OutfitsModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 120))]) {
            ForEach(ids, id: \.self) { id in
                VStack(alignment: .leading) {
                    if let garment = model.garments.first(where: { $0.id == id }) {
                        WardrobeThumbnail(imageID: garment.imageID, repository: model.wardrobe)
                        Text(verbatim: garment.name)
                        if garment.archived {
                            Label("outfits.archived", systemImage: "exclamationmark.triangle").font(.caption)
                        }
                    } else { Label("outfits.missing", systemImage: "exclamationmark.triangle") }
                }
            }
        }
    }
}

private struct OutfitEditor: View {
    @ObservedObject var model: OutfitsModel
    @State var draft: Outfit
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    private var locked: Bool { model.saving || model.pending != nil }

    var body: some View {
        Form {
            Section {
                TextField("outfits.name", text: $draft.name)
                Toggle("outfits.favorite", isOn: $draft.favorite)
            }.disabled(locked)
            Section("outfits.collage") {
                OutfitCollage(ids: draft.garmentIDs, model: model)
                Text("outfits.historyUnchanged").font(.caption)
            }
            Section("outfits.choose") {
                if model.garments.isEmpty { Text("wardrobe.noResults") }
                ForEach(model.garments.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { garment in
                    Toggle(isOn: Binding(get: { draft.garmentIDs.contains(garment.id) }, set: { selected in
                        if selected { draft.garmentIDs.append(garment.id) }
                        else { draft.garmentIDs.removeAll { $0 == garment.id } }
                    })) {
                        VStack(alignment: .leading) {
                            Text(verbatim: garment.name)
                            if garment.archived { Label("outfits.archived", systemImage: "exclamationmark.triangle") }
                            Text(LocalizedStringKey("wardrobe.\(garment.availability.rawValue)"))
                        }
                    }
                    .disabled(locked || (draft.garmentIDs.count >= 100 && !draft.garmentIDs.contains(garment.id)))
                }
                // A removed garment stays visible until the user explicitly removes it.
                ForEach(draft.garmentIDs.filter { id in !model.garments.contains { $0.id == id } }, id: \.self) { id in
                    Button("outfits.removeMissing") { draft.garmentIDs.removeAll { $0 == id } }.disabled(locked)
                }
            }
            if let key = model.errorKey { Text(LocalizedStringKey(key)) }
            if model.pending != nil { Text("outfits.retryPending") }
        }
        .searchable(text: $search, prompt: "wardrobe.search")
        .navigationTitle("outfits.editor")
        .interactiveDismissDisabled(model.saving)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }.disabled(model.saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { if await model.save(draft) { dismiss() } }
                } label: {
                    Text(LocalizedStringKey(model.pending == nil ? "common.save" : "common.retry"))
                }.disabled(model.saving || (try? draft.validate()) == nil)
            }
        }
    }
}
