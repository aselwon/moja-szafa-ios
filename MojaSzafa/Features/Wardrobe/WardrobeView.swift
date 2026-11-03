import SwiftUI

struct WardrobeView: View {
    @StateObject private var model: WardrobeModel
    @StateObject private var imports: PhotoImportModel
    @Environment(\.dynamicTypeSize) private var typeSize

    init(repository: any WardrobeRepository, accountID: UUID) {
        _imports = StateObject(wrappedValue: PhotoImportModel(directory: URL.applicationSupportDirectory
            .appendingPathComponent("PhotoDrafts").appendingPathComponent(accountID.uuidString)))
        _model = StateObject(wrappedValue: WardrobeModel(repository: repository))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink("import.title") { PhotoImportView(model: imports) }
                controls
                if model.cached { Text("wardrobe.cached").font(.callout) }
                switch model.state {
                case .idle, .loading: ProgressView("common.loading")
                case .empty: Text("wardrobe.noResults")
                case .loaded:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 145))], spacing: 16) {
                        ForEach(model.items) { garment in
                            NavigationLink {
                                GarmentDetailView(id: garment.id, repository: model.repository)
                            } label: {
                                VStack(alignment: .leading) {
                                    WardrobeThumbnail(imageID: garment.imageID, repository: model.repository)
                                    Text(verbatim: garment.name).font(.headline)
                                    Text(LocalizedStringKey("garment.category.\(garment.category.rawValue)"))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if model.nextOffset != nil {
                        if model.pageFailed {
                            Text(LocalizedStringKey(model.pageOffline ? "foundation.offline" : "foundation.loadFailed"))
                        }
                        Button {
                            Task { await model.loadMore() }
                        } label: { Text(LocalizedStringKey(model.pageFailed ? "common.retry" : "wardrobe.more")) }
                        .disabled(model.loadingMore)
                        if model.loadingMore { ProgressView("common.loading") }
                    }
                case .backendNotConfigured: Text("foundation.serviceUnavailable")
                case .offline:
                    Text("foundation.offline")
                    retryButton
                case .failed:
                    Text("foundation.loadFailed")
                    retryButton
                }
            }.padding(16)
        }
        .foregroundStyle(Color("primaryText"))
        .background(Color("background"))
        .navigationTitle("tab.wardrobe")
        .searchable(text: $model.query.search, prompt: "wardrobe.search")
        .task(id: model.query) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await model.reload()
        }
        .refreshable { await model.reload() }
    }

    private var controls: some View {
        VStack(alignment: .leading) {
            Picker("garment.category", selection: $model.query.category) {
                Text("wardrobe.all").tag(nil as APIv1.Category?)
                ForEach(APIv1.Category.allCases, id: \.self) {
                    Text(LocalizedStringKey("garment.category.\($0.rawValue)")).tag(Optional($0))
                }
            }
            Picker("wardrobe.availability", selection: $model.query.availability) {
                Text("wardrobe.all").tag(nil as APIv1.Availability?)
                ForEach(APIv1.Availability.allCases, id: \.self) {
                    Text(LocalizedStringKey("wardrobe.\($0.rawValue)")).tag(Optional($0))
                }
            }
            Picker("wardrobe.sort", selection: $model.query.sort) {
                ForEach(WardrobeQuery.Sort.allCases, id: \.self) {
                    Text(LocalizedStringKey("wardrobe.sort.\($0.rawValue)")).tag($0)
                }
            }
            Toggle("wardrobe.archived", isOn: $model.query.archived)
        }
    }

    private var retryButton: some View {
        Button("common.retry") { Task { await model.reload() } }.buttonStyle(.bordered)
    }
}

/// Bytes live only in the visible view. There is deliberately no URLCache or
/// automatic original fallback; only the detail toggle requests a full photo.
private struct WardrobeThumbnail: View {
    let imageID: UUID?
    let repository: any WardrobeRepository
    var original = false
    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true) }
            else if loading { ProgressView("common.loading") }
            else { Label("wardrobe.noPhoto", systemImage: "photo").font(.caption) }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .task(id: "\(imageID?.uuidString ?? "none")-\(original)") {
            image = nil
            guard let imageID else { return }
            loading = true
            defer { loading = false }
            do {
                let bytes: Data
                if original { bytes = try await repository.original(imageID: imageID) }
                else { bytes = try await repository.thumbnail(imageID: imageID) }
                try Task.checkCancellation()
                image = UIImage(data: bytes)
            } catch { image = nil }
        }
        .onDisappear { image = nil }
    }
}

private struct GarmentDetailView: View {
    let id: UUID
    let repository: any WardrobeRepository
    @State private var detail: GarmentDetail?
    @State private var failure = false
    @State private var retry = 0
    @State private var showOriginal = false

    var body: some View {
        List {
            if let detail {
                if detail.cached { Text("wardrobe.cached") }
                Section {
                    WardrobeThumbnail(imageID: detail.garment.imageID, repository: repository, original: showOriginal)
                    if detail.garment.imageID != nil {
                        Toggle("wardrobe.original", isOn: $showOriginal)
                    }
                    Text(verbatim: detail.garment.name).font(.title2)
                    Text(LocalizedStringKey("garment.category.\(detail.garment.category.rawValue)"))
                    Text(LocalizedStringKey("wardrobe.\(detail.garment.availability.rawValue)"))
                    if let brand = detail.garment.brand { LabeledContent("garment.brand", value: brand) }
                    if let price = detail.garment.priceGrosz {
                        LabeledContent("garment.price", value: (Decimal(price) / 100).formatted(.currency(code: "PLN")))
                    } else { Text("wardrobe.noPrice") }
                    ForEach(detail.garment.colors, id: \.self) { Text(LocalizedStringKey("garment.color.\($0)")) }
                    ForEach(detail.garment.seasons, id: \.self) { Text(LocalizedStringKey("garment.season.\($0)")) }
                }
                Section("wardrobe.history") {
                    Text("wardrobe.historyExplanation").font(.caption)
                    if detail.wornOn.isEmpty { Text("wardrobe.neverWorn") }
                    ForEach(detail.wornOn, id: \.self) { day in Text(verbatim: day) }
                }
            } else if failure {
                Text("wardrobe.detailFailed")
                Button("common.retry") { retry += 1 }
            } else { ProgressView("common.loading") }
        }
        .navigationTitle("garment.details")
        .task(id: retry) {
            failure = false
            do {
                let result = try await repository.detail(id: id)
                try Task.checkCancellation()
                detail = result
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
}
