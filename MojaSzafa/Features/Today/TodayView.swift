import SwiftUI

struct TodayView: View {
    @StateObject private var model: SuggestionsModel
    @State private var weather: WeatherModel
    @State private var generationTask: Task<Void, Never>?
    @State private var count = 3
    @State private var showPrivacy = false
    private let consent: (any AIConsentService)?
    @State private var replacement: ReplacementSelection?

    init(dependencies: AppDependencies, accountID: UUID) {
        _weather = State(initialValue: WeatherModel(service: AppleCityWeatherService(repository: dependencies.weather)))
        consent = dependencies.aiConsent
        let intentURL = dependencies.generationIntentURL(accountID: accountID)
        _model = StateObject(wrappedValue: SuggestionsModel(source: dependencies.suggestions,
            wardrobe: dependencies.wardrobe, outfits: dependencies.outfits, offline: dependencies.offline, intentURL: intentURL))
    }

    private var generationWeather: GenerationWeatherContext? {
        guard let context = weather.context() else { return nil }
        return GenerationWeatherContext(temperature_celsius: context.temperatureCelsius,
            source: context.source == .manual ? "manual" : "forecast",
            valid_until: context.source == .forecast ? weather.forecast.map { Int($0.validAt.timeIntervalSince1970) } : nil)
    }

    var body: some View {
        List {
            WeatherControls(weather: weather)
            Section {
                Text("generation.count")
                Stepper("\(count)", value: $count, in: 1...10)
                    .accessibilityLabel(Text("generation.count"))
                    .disabled(model.pendingGeneration != nil || model.generating)
                Button(model.pendingGeneration == nil ? "generation.start" : "common.retry") {
                    generationTask = Task { await model.generate(count: count, weather: generationWeather) }
                }.disabled(model.generating || model.loading || model.busy || model.saves.pending != nil)
                if model.generating { ProgressView("generation.progress") }
                if let status = model.generationStatus, status == .queued || status == .running {
                    Text(LocalizedStringKey("generation.\(status.rawValue)"))
                }
                if let key = model.generationError { Text(LocalizedStringKey(key)) }
                Button("privacy.title") { showPrivacy = true }
            } header: { Text("generation.title") }
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
                        .disabled(model.generating || model.busy || model.saves.pending != nil)
                    }
                    Button(LocalizedStringKey(suggestion.outfit.version > 0 ? "suggestions.saved" : "outfits.save")) {
                        Task { await model.save(suggestion.id) }
                    }.disabled(model.generating || model.busy || (model.saves.pending != nil && model.saves.pending?.id != suggestion.id))
                    Button(LocalizedStringKey(suggestion.worn ? "suggestions.worn" : "suggestions.wear")) {
                        Task { await model.wear(suggestion.id) }
                    }.disabled(model.generating || model.busy || suggestion.worn || model.saves.pending != nil)
                }
            }
            if model.saves.pending != nil { Text("outfits.pending") }
            if model.busy { ProgressView("common.loading") }
        }
        .navigationTitle("tab.today")
        .task {
            if model.pendingGeneration != nil { await model.generate(count: count, weather: generationWeather) }
            else { await model.load() }
        }
        .onDisappear { generationTask?.cancel(); weather.clear() }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack { AIPrivacyView(service: consent) }
        }
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

private struct WeatherControls: View {
    @Bindable var weather: WeatherModel
    var body: some View {
        Group {
            Section {
                Text("weather.optional")
                TextField("weather.city", text: $weather.query)
                    .textContentType(.addressCity)
                Button("weather.search") { Task { await weather.search() } }
                    .disabled(weather.busy || weather.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("weather.locate", systemImage: "location") { Task { await weather.locate() } }
                    .disabled(weather.busy)
                ForEach(Array(weather.cities.enumerated()), id: \.offset) { _, city in
                    Button(city.name) { Task { await weather.select(city) } }
                        .disabled(weather.busy)
                }
                if weather.busy { ProgressView() }
                if let message = weather.message { Text(LocalizedStringKey(message)) }
            } header: { Text("weather.title") }
            if let city = weather.city {
                Section {
                    Text(city.name)
                    LabeledContent("weather.timeZone", value: city.timeZone.identifier)
                    if let forecast = weather.forecast {
                        Text(Measurement(value: forecast.celsius, unit: UnitTemperature.celsius), format: .measurement(width: .abbreviated, usage: .asProvided))
                        LabeledContent("weather.validAt", value: date(forecast.validAt, zone: city.timeZone))
                        LabeledContent("weather.updatedAt", value: date(forecast.updatedAt, zone: city.timeZone))
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            if !weather.useManualTemperature && weather.context(now: timeline.date) == nil {
                                Text("weather.stale")
                            }
                        }
                        Link(forecast.source, destination: forecast.attributionURL)
                        if let license = forecast.licenseURL {
                            Link("CC BY 4.0", destination: license)
                        }
                    }
                    Button("weather.refresh") { Task { await weather.select(city) } }.disabled(weather.busy)
                }
            }
            Section {
                Toggle("weather.manual", isOn: $weather.useManualTemperature)
                if weather.useManualTemperature {
                    TextField("weather.temperature", text: $weather.manualTemperature)
                    Text("weather.range")
                }
                Text("weather.fallback")
                Button("weather.clear") { weather.clear() }
            }
        }
    }
    private func date(_ value: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = zone
        return formatter.string(from: value)
    }
}

struct WearHistoryView: View {
    var store: OfflineStore? = nil
    @State private var state: OfflineStore.State?
    @State private var editing: SyncWear?
    @State private var errorKey: String?
    @State private var loading = false
    @State private var selectedDate = Date()
    private var selectedDay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: selectedDate)
    }

    var body: some View {
        List {
            DatePicker("wear.historyDate", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
            if loading { ProgressView("common.loading") }
            if store == nil { Text("foundation.serviceUnavailable") }
            if let errorKey { Text(LocalizedStringKey(errorKey)) }
            if let state {
                if !state.outbox.isEmpty { Text("wear.pending") }
                if state.wears.filter({ !$0.deleted && $0.wornOn == selectedDay }).isEmpty { Text("wear.historyEmpty") }
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
                if let removed = state.wears.first(where: { $0.id == state.lastRemovedWearID && $0.deleted }) {
                    Button("wear.undoRemoval") { Task { await visibility(removed, removed: false) } }
                        .disabled(loading || state.outbox.contains { $0.visibility?.id == removed.id && $0.sent })
                }
                ForEach(state.outbox.filter { $0.visibility != nil && $0.failure != nil }, id: \.id) { pending in
                    Text("wear.conflict")
                    Button("wear.discardLocal") {
                        Task {
                            do { try await store?.discardVisibilityConflict(id: pending.visibility!.id); await reload() }
                            catch { errorKey = "wear.syncFailed" }
                        }
                    }
                }
                ForEach(state.wears.filter { !$0.deleted && $0.wornOn == selectedDay }.sorted { $0.id.uuidString < $1.id.uuidString }) { wear in
                    Button { editing = wear } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: wear.wornOn).font(.headline)
                            Text(verbatim: wear.timezone).font(.caption)
                            Text(verbatim: wear.garmentIDs.compactMap { id in
                                state.garments.first { $0.id == id }?.fields.name
                            }.joined(separator: ", "))
                        }
                    }
                    Button("wear.remove", role: .destructive) { Task { await visibility(wear, removed: true) } }
                        .disabled(loading || state.outbox.contains { $0.visibility?.id == wear.id || $0.wear?.wear.id == wear.id })
                }
            }
            Button("common.retry") { Task { await reload() } }.disabled(loading || store == nil)
        }
        .navigationTitle("wear.history")
        .toolbar {
            Button("wear.new") { editing = WearEditor.newWear(day: selectedDay) }.disabled(store == nil || loading)
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $editing, onDismiss: { Task { await reload() } }) { wear in
            if let store { NavigationStack { WearEditor(wear: wear, store: store) } }
        }
    }

    @MainActor private func visibility(_ wear: SyncWear, removed: Bool) async {
        do {
            try await store?.setWearRemoved(id: wear.id, version: wear.version, removed: removed)
            await reload()
        } catch { errorKey = "wear.saveFailed" }
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

    static func newWear(garmentIDs: [UUID] = [], day: String? = nil) -> SyncWear {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return SyncWear(id: UUID(), version: 0, deleted: false, wornOn: day ?? formatter.string(from: Date()),
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
