import SwiftUI

struct OutfitsView: View {
    @StateObject private var model: OutfitsModel
    let wardrobe: any WardrobeRepository
    @State private var editing: Outfit?
    @State private var favoritesOnly = false

    init(repository: any OutfitRepository, wardrobe: any WardrobeRepository) {
        _model = StateObject(wrappedValue: OutfitsModel(repository: repository))
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
            }
            if model.nextCursor != nil {
                Button("wardrobe.more") { Task { await model.load(more: true) } }.disabled(model.loading)
            }
        }
        .navigationTitle("tab.outfits")
        .toolbar { Button("outfits.new") { editing = model.pendingDraft ?? Outfit() } }
        .task { await model.load() }
        .refreshable { await model.load() }
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
