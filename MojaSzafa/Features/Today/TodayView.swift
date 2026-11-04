import SwiftUI

struct TodayView: View {
    @StateObject private var model: SuggestionsModel
    @State private var replacement: ReplacementSelection?

    init(dependencies: AppDependencies) {
        _model = StateObject(wrappedValue: SuggestionsModel(source: dependencies.suggestions,
            wardrobe: dependencies.wardrobe, outfits: dependencies.outfits, offline: dependencies.offline))
    }

    var body: some View {
        List {
            if model.loading { ProgressView("common.loading") }
            if let key = model.errorKey {
                Text(LocalizedStringKey(key))
                Text("suggestions.manualFallback")
                Button("common.retry") { Task { await model.load() } }
            }
            if model.items.isEmpty && !model.loading { Text("suggestions.empty") }
            if let shortfall = model.shortfall { Text(verbatim: shortfall) }
            ForEach(model.items) { suggestion in
                Section {
                    OutfitCollage(garments: suggestion.outfit.garments, repository: model.wardrobe)
                    if suggestion.edited { Text("suggestions.edited") }
                    else { Text(verbatim: suggestion.rationale) }
                    if !suggestion.missing.isEmpty {
                        Text("suggestions.incomplete").font(.headline)
                        ForEach(suggestion.missing, id: \.self) { category in
                            Text(LocalizedStringKey("garment.category.\(category.rawValue)"))
                        }
                    }
                    ForEach(suggestion.outfit.garments) { garment in
                        Button {
                            replacement = ReplacementSelection(suggestionID: suggestion.id, garment: garment,
                                excluded: Set(suggestion.outfit.garments.map(\.id)))
                        } label: {
                            Label { Text(verbatim: garment.name) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        }.accessibilityHint(Text("suggestions.replace"))
                        .disabled(model.busy || model.saves.pending != nil)
                    }
                    Button(LocalizedStringKey(suggestion.outfit.version > 0 ? "suggestions.saved" : "outfits.save")) {
                        Task { await model.save(suggestion.id) }
                    }.disabled(model.busy || (model.saves.pending != nil && model.saves.pending?.id != suggestion.id))
                    Button(LocalizedStringKey(suggestion.worn ? "suggestions.worn" : "suggestions.wear")) {
                        Task { await model.wear(suggestion.id) }
                    }.disabled(model.busy || suggestion.worn || model.saves.pending != nil)
                }
            }
            if model.saves.pending != nil { Text("outfits.pending") }
            if model.busy { ProgressView("common.loading") }
        }
        .navigationTitle("tab.today")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $replacement) { selection in
            NavigationStack {
                SuggestionReplacementPicker(selection: selection, model: model)
            }
        }
    }
}

private struct ReplacementSelection: Identifiable {
    let suggestionID: UUID
    let garment: Garment
    let excluded: Set<UUID>
    var id: UUID { garment.id }
}

private struct SuggestionReplacementPicker: View {
    let selection: ReplacementSelection
    @ObservedObject var model: SuggestionsModel
    @StateObject private var picker: WardrobeModel
    @Environment(\.dismiss) private var dismiss

    init(selection: ReplacementSelection, model: SuggestionsModel) {
        self.selection = selection; self.model = model
        _picker = StateObject(wrappedValue: WardrobeModel(repository: model.wardrobe))
    }

    var body: some View {
        List {
            Text("suggestions.manualFallback")
            TextField("wardrobe.search", text: $picker.query.search)
            if picker.state == .loading { ProgressView("common.loading") }
            if picker.items.filter({ !selection.excluded.contains($0.id) }).isEmpty { Text("wardrobe.noResults") }
            ForEach(picker.items.filter { !selection.excluded.contains($0.id) }) { garment in
                Button {
                    Task {
                        await model.replace(suggestionID: selection.suggestionID, garmentID: selection.garment.id, with: garment)
                        if model.errorKey == nil { dismiss() }
                    }
                } label: {
                    HStack {
                        WardrobeThumbnail(imageID: garment.imageID, repository: model.wardrobe)
                            .frame(width: 64, height: 64)
                        Text(verbatim: garment.name)
                    }
                }.disabled(model.busy)
            }
            if let key = model.errorKey { Text(LocalizedStringKey(key)) }
            if picker.state == .failed || picker.state == .offline || picker.state == .backendNotConfigured || picker.pageFailed {
                Text("outfits.offline")
                Button("common.retry") { Task { await picker.reload() } }
            }
            if picker.nextOffset != nil {
                Button("wardrobe.more") { Task { await picker.loadMore() } }.disabled(picker.loadingMore)
            }
        }
        .navigationTitle("suggestions.replace")
        .toolbar { Button("outfits.cancel") { dismiss() }.disabled(model.busy) }
        .interactiveDismissDisabled(model.busy)
        .task { picker.query.availability = .available }
        .task(id: picker.query) { await picker.reload() }
    }
}
