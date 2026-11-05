import SwiftUI

struct WardrobeView: View {
    @StateObject private var model: WardrobeModel
    @StateObject private var imports: PhotoImportModel
    private let allowsPhotoImport: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase

    init(repository: any WardrobeRepository, accountID: UUID, allowsPhotoImport: Bool = true) {
        self.allowsPhotoImport = allowsPhotoImport
        _imports = StateObject(wrappedValue: PhotoImportModel(directory: URL.applicationSupportDirectory
            .appendingPathComponent("PhotoDrafts").appendingPathComponent(accountID.uuidString)))
        _model = StateObject(wrappedValue: WardrobeModel(repository: repository))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if allowsPhotoImport {
                    NavigationLink("import.title") { PhotoImportView(model: imports, repository: model.repository) }
                }
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
                                    Text(LocalizedStringKey("garment.category." + garment.category.rawValue))
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.reload() } }
        }
        .onAppear { Task { await model.load() } }
    }

    private var controls: some View {
        VStack(alignment: .leading) {
            Picker("garment.category", selection: $model.query.category) {
                Text("wardrobe.all").tag(nil as APIv1.Category?)
                ForEach(APIv1.Category.allCases, id: \.self) {
                    Text(LocalizedStringKey("garment.category." + $0.rawValue)).tag(Optional($0))
                }
            }
            Picker("wardrobe.availability", selection: $model.query.availability) {
                Text("wardrobe.all").tag(nil as APIv1.Availability?)
                ForEach(APIv1.Availability.allCases, id: \.self) {
                    Text(LocalizedStringKey("wardrobe." + $0.rawValue)).tag(Optional($0))
                }
            }
            Picker("wardrobe.sort", selection: $model.query.sort) {
                ForEach(WardrobeQuery.Sort.allCases, id: \.self) {
                    Text(LocalizedStringKey("wardrobe.sort." + $0.rawValue)).tag($0)
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
struct WardrobeThumbnail: View {
    let imageID: UUID?
    let repository: any WardrobeRepository
    var original = false
    var height: CGFloat = 150
    var cleaned = false
    @State private var image: UIImage?
    @State private var loading = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true) }
            else if loading { ProgressView("common.loading") }
            else { Label("wardrobe.noPhoto", systemImage: "photo").font(.caption) }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .task(id: "\(imageID?.uuidString ?? "none")-\(original)-\(cleaned)") {
            image = nil
            guard let imageID else { return }
            loading = true
            defer { loading = false }
            do {
                let bytes: Data
                if cleaned { bytes = try await repository.cleaned(imageID: imageID) }
                else if original { bytes = try await repository.original(imageID: imageID) }
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
    @State private var saving = false
    @State private var statusMessage: String?
    @State private var conflict = false
    @State private var confirmDeletion = false
    @State private var editInitialHistory = false
    @State private var editAttributes = false
    @State private var initialHistoryConflict = false
    @Environment(\.dismiss) private var dismiss


    var body: some View {
        List {
            if let detail {
                if detail.cached { Text("wardrobe.cached") }
                Section {
                    WardrobeThumbnail(imageID: detail.garment.imageID, repository: repository, original: showOriginal || detail.garment.hasCleanedImage != true,
                        cleaned: !showOriginal && detail.garment.hasCleanedImage == true)
                    if detail.garment.imageID != nil && detail.garment.hasCleanedImage == true {
                        Toggle("wardrobe.original", isOn: $showOriginal)
                    }
                    Text(verbatim: detail.garment.name).font(.title2)
                    Button("garment.editDetails") { editAttributes = true }
                        .disabled(saving || detail.garment.editableValue == nil || detail.garment.version == nil)
                    Text(LocalizedStringKey("garment.category." + detail.garment.category.rawValue))
                    Text(LocalizedStringKey("wardrobe." + detail.garment.availability.rawValue))
                    if let brand = detail.garment.brand { LabeledContent("garment.brand", value: brand) }
                    if let price = detail.garment.priceGrosz {
                        LabeledContent("garment.price", value: (Decimal(price) / 100).formatted(.currency(code: "PLN")))
                    } else { Text("wardrobe.noPrice") }
                    LabeledContent {
                        if let grosz = detail.costPerWear.roundedGrosz {
                            Text((Decimal(grosz) / 100).formatted(.currency(code: "PLN")))
                        } else if detail.costPerWear.priceGrosz == nil {
                            Text("wardrobe.noPrice")
                        } else {
                            Text("cpw.neverWorn")
                        }
                    } label: { Text(LocalizedStringKey(detail.costPerWear.isEstimated ? "initialHistory.estimatedCPW" : "cpw.lifetime")) }
                    ForEach(detail.garment.colors, id: \.self) { Text(LocalizedStringKey("garment.color." + $0)) }
                    ForEach(detail.garment.seasons, id: \.self) { Text(LocalizedStringKey("garment.season." + $0)) }
                }
                Section("wardrobe.availability") {
                    Picker("wardrobe.availability", selection: Binding(
                        get: { detail.garment.availability },
                        set: { update(availability: $0, archived: detail.garment.archived) })) {
                        ForEach(APIv1.Availability.allCases, id: \.self) {
                            Text(LocalizedStringKey("wardrobe." + $0.rawValue)).tag($0)
                        }
                    }
                    Toggle("wardrobe.archived", isOn: Binding(
                        get: { detail.garment.archived },
                        set: { update(availability: detail.garment.availability, archived: $0) }))
                    Text("wardrobe.statusExplanation").font(.caption)
                    if saving { ProgressView("common.loading") }
                    if let statusMessage { Text(LocalizedStringKey(statusMessage)) }
                    if conflict {
                        Button("wardrobe.useServer") { resolve(keepLocal: false) }
                        if !initialHistoryConflict { Button("wardrobe.keepLocal") { resolve(keepLocal: true) } }
                    } else if statusMessage != nil {
                        Button("common.retry") { Task { await synchronizeStatus() } }
                    }
                }.disabled(saving)
                Section {
                    Button("wardrobe.delete", role: .destructive) { confirmDeletion = true }
                        .disabled(saving)
                }
                Section("initialHistory.title") {
                    Text("initialHistory.explanation").font(.caption)
                    if let history = detail.garment.initialWearHistory {
                        LabeledContent("initialHistory.count", value: String(history.count))
                        LabeledContent("initialHistory.boundary", value: history.startDate)
                    }
                    Button("initialHistory.edit") { editInitialHistory = true }.disabled(saving)
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
        .sheet(isPresented: $editAttributes, onDismiss: { retry += 1 }) {
            if let garment = detail?.garment, let value = garment.editableValue, let version = garment.version {
                GarmentFormView(value: value, editingExisting: true) { edited in
                    detail = try await repository.editGarment(id: id, expectedVersion: version, value: edited)
                }
            }
        }
        .sheet(isPresented: $editInitialHistory) {
            if let detail {
                NavigationStack {
                    InitialHistoryEditor(detail: detail, repository: repository) {
                        retry += 1
                        editInitialHistory = false
                    }
                }
            }
        }
        .confirmationDialog("wardrobe.delete", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("wardrobe.delete", role: .destructive) {
                Task {
                    saving = true
                    defer { saving = false }
                    do {
                        try await repository.deleteGarment(id: id)
                        detail = nil
                        dismiss()
                    } catch { statusMessage = "wardrobe.statusFailed" }
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("wardrobe.deleteExplanation") }
        .task(id: retry) {
            failure = false
            do {
                let result = try await repository.detail(id: id)
                try Task.checkCancellation()
                detail = result
                await synchronizeStatus()
            } catch { if !Task.isCancelled { failure = true } }
        }
    }
    private func update(availability: APIv1.Availability, archived: Bool) {
        Task {
            saving = true
            defer { saving = false }
            do {
                detail = try await repository.setStatus(id: id, availability: availability, archived: archived)
                await synchronizeStatus()
            } catch { statusMessage = "wardrobe.statusFailed" }
        }
    }

    private func synchronizeStatus() async {
        guard let store = repository as? OfflineStore else { return }
        do {
            try await store.synchronize()
            let state = await store.status()
            let pending = state.outbox.first { $0.garment?.garmentID == id || $0.initialHistory?.id == id }
            initialHistoryConflict = pending?.initialHistory != nil
            conflict = pending?.failure != nil
            statusMessage = conflict ? "wardrobe.statusConflict" : (pending == nil ? nil : "wardrobe.statusPending")
            detail = try await store.detail(id: id)
        } catch {
            let state = await store.status()
            let pending = state.outbox.first { $0.garment?.garmentID == id || $0.initialHistory?.id == id }
            initialHistoryConflict = pending?.initialHistory != nil
            conflict = pending?.failure != nil
            statusMessage = conflict ? "wardrobe.statusConflict" : "wardrobe.statusPending"
        }
    }

    private func resolve(keepLocal: Bool) {
        guard let store = repository as? OfflineStore else { return }
        Task {
            saving = true
            defer { saving = false }
            do {
                if initialHistoryConflict { try await store.discardInitialHistoryConflict(id: id) }
                else { try await store.resolveGarment(id: id, keepLocal: keepLocal) }
                await synchronizeStatus()
            } catch { statusMessage = "wardrobe.statusFailed" }
        }
    }

}

private struct InitialHistoryEditor: View {
    let detail: GarmentDetail
    let repository: any WardrobeRepository
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var count: String
    @State private var boundary: Date
    @State private var confirmOverlap = false
    @State private var saving = false
    @State private var failed = false

    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    init(detail: GarmentDetail, repository: any WardrobeRepository, saved: @escaping () -> Void) {
        self.detail = detail; self.repository = repository; self.saved = saved
        _count = State(initialValue: String(detail.garment.initialWearHistory?.count ?? 0))
        _boundary = State(initialValue: detail.garment.initialWearHistory.flatMap { Self.formatter.date(from: $0.startDate) } ?? Date())
    }
    private var day: String { Self.formatter.string(from: boundary) }
    private var needsConfirmation: Bool {
        detail.garment.initialWearHistory?.startDate != day && detail.wornOn.contains { $0 < max(day, detail.garment.initialWearHistory?.startDate ?? day) }
    }
    var body: some View {
        Form {
            Text("initialHistory.explanation")
            TextField("initialHistory.count", text: $count).keyboardType(.numberPad)
            DatePicker("initialHistory.boundary", selection: $boundary, displayedComponents: .date)
            if needsConfirmation {
                Text("initialHistory.overlap")
                Toggle("initialHistory.confirm", isOn: $confirmOverlap)
            }
            if failed { Text("initialHistory.failed") }
            Button("common.save") {
                guard let value = Int(count) else { return }
                save(InitialWearHistory(count: value, startDate: day))
            }.disabled(saving || Int(count).map { !(0...1_000_000).contains($0) } != false || (needsConfirmation && !confirmOverlap))
            Button("initialHistory.clear", role: .destructive) { save(nil) }.disabled(saving)
        }
        .navigationTitle("initialHistory.title")
        .toolbar { Button("common.cancel") { dismiss() }.disabled(saving) }
        .onChange(of: boundary) { _, _ in confirmOverlap = false }
    }
    private func save(_ history: InitialWearHistory?) {
        Task {
            saving = true; failed = false
            defer { saving = false }
            do {
                _ = try await repository.setInitialHistory(id: detail.garment.id, history: history, confirmOverlap: confirmOverlap)
                saved()
            } catch { failed = true }
        }
    }
}
