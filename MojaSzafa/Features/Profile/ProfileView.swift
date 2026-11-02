import SwiftUI

struct WelcomeView: View {
    let continueAction: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("welcome.wardrobe", systemImage: "tshirt")
                    Label("welcome.outfits", systemImage: "square.stack")
                    Label("welcome.history", systemImage: "calendar")
                } header: { Text("welcome.value") }
                Section {
                    Text("welcome.example")
                    Text("welcome.exampleDetail")
                } header: { Text("welcome.exampleTitle") }
                Section {
                    Text("welcome.free")
                    Button("welcome.continue", action: continueAction)
                    Button("onboarding.skip", action: continueAction)
                }
            }
            .navigationTitle("welcome.title")
        }
    }
}

struct ProfilePreferencesFields: View {
    @Binding var draft: ProfilePreferences

    var body: some View {
        Section { Text("profile.optional"); Text("profile.local") }
        choices("profile.styles", options: ProfilePreferences.styles, selection: $draft.styles)
        choices("profile.colors", options: ProfilePreferences.colors, selection: $draft.colors)
        choices("profile.priorities", options: ProfilePreferences.priorities, selection: $draft.priorities)
    }

    private func choices(_ title: String, options: [String], selection: Binding<Set<String>>) -> some View {
        Section {
            ForEach(options, id: \.self) { option in
                Toggle(LocalizedStringKey("\(title).\(option)"), isOn: Binding(
                    get: { selection.wrappedValue.contains(option) },
                    set: { selected in
                        if selected { selection.wrappedValue.insert(option) }
                        else { selection.wrappedValue.remove(option) }
                    }))
            }
        } header: { Text(LocalizedStringKey(title)) }
    }
}

struct ProfileEditorView: View {
    let model: ProfileModel
    let onboarding: Bool
    @State private var draft: ProfilePreferences
    @Environment(\.dismiss) private var dismiss

    init(model: ProfileModel, onboarding: Bool = false) {
        self.model = model
        self.onboarding = onboarding
        _draft = State(initialValue: model.saved)
    }

    var body: some View {
        Form {
            ProfilePreferencesFields(draft: $draft)
            if let message = model.message { Text(LocalizedStringKey(message)) }
            Section {
                Button(LocalizedStringKey(onboarding ? "onboarding.finish" : "profile.save")) {
                    if onboarding { model.finish(draft) }
                    else if model.save(draft) { dismiss() }
                }
                if onboarding {
                    Button("onboarding.skip") { model.finish(draft, skipping: true) }
                } else {
                    Button("auth.cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .navigationTitle(LocalizedStringKey(onboarding ? "onboarding.title" : "profile.title"))
    }
}

struct ProfileGateView: View {
    let dependencies: AppDependencies
    private let accountID: UUID
    @State private var model: ProfileModel
    @State private var showProfile = false

    init(dependencies: AppDependencies, accountID: UUID) {
        self.dependencies = dependencies
        self.accountID = accountID
        _model = State(initialValue: ProfileModel(accountID: accountID))
    }

    var body: some View {
        Group {
            if !model.loaded {
                VStack {
                    if let message = model.message {
                        Text(LocalizedStringKey(message))
                        Button("profile.retry") { model.load() }
                    } else { ProgressView() }
                }
            } else if !model.saved.onboardingCompleted {
                NavigationStack { ProfileEditorView(model: model, onboarding: true) }
            } else {
                AppRootView(dependencies: dependencies, accountID: accountID)
                    .safeAreaInset(edge: .top) {
                        Button("profile.title") { showProfile = true }.padding(8)
                    }
                    .sheet(isPresented: $showProfile) {
                        NavigationStack {
                            List {
                                NavigationLink("profile.title") { ProfileEditorView(model: model) }
                                NavigationLink("export.title") { DataExportView(service: dependencies.dataExport) }
                                NavigationLink("privacy.title") { AIPrivacyView(service: dependencies.aiConsent) }
                            }.navigationTitle("profile.title")
                        }
                    }
            }
        }
        .task { model.load() }
    }
}

struct AIPrivacyView: View {
    @State private var model: AIConsentModel

    init(service: (any AIConsentService)?) {
        _model = State(initialValue: AIConsentModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                Text("privacy.manual")
                Text("privacy.inflight")
            }
            if let snapshot = model.snapshot {
                Section {
                    Text(snapshot.granted ? "privacy.allowed" : "privacy.blocked")
                    if let disclosure = snapshot.disclosure {
                        LabeledContent("privacy.recipient", value: disclosure.recipient)
                        LabeledContent("privacy.data", value: disclosure.data_description)
                        LabeledContent("privacy.purpose", value: disclosure.purpose_description)
                        LabeledContent("privacy.version", value: disclosure.policy_version)
                        if !snapshot.granted {
                            Button("privacy.allow") { Task { await model.choose(true) } }
                                .disabled(model.busy || model.pending != nil)
                        }
                    } else { Text("privacy.unconfigured") }
                    Button(snapshot.granted ? "privacy.revoke" : "privacy.deny", role: .destructive) {
                        Task { await model.choose(false) }
                    }.disabled(model.busy || model.pending != nil)
                }
            }
            if model.busy { ProgressView() }
            if let message = model.message {
                Section {
                    Text(LocalizedStringKey(message))
                    Button("profile.retry") {
                        Task {
                            if let pending = model.pending { await model.choose(pending.granted) }
                            else { await model.load() }
                        }
                    }.disabled(model.busy)
                }
            }
        }
        .navigationTitle("privacy.title")
        .task { await model.load() }
    }
}

struct DataExportView: View {
    let service: (any DataExportService)?
    @State private var ticket: ExportTicket?
    @State private var file: URL?
    @State private var busy = false
    @State private var failed = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        Form {
            Text("export.explanation")
            Text("export.local")
            if service == nil { Text("export.unconfigured") }
            if let ticket { LabeledContent("export.expires", value: ticket.expires_at) }
            if busy { ProgressView() }
            if failed { Text("export.error") }
            Button("export.request") {
                operation = Task { await prepare() }
            }.disabled(busy || service == nil)
            if let file { ShareLink(item: file) { Label("export.share", systemImage: "square.and.arrow.up") } }
        }
        .navigationTitle("export.title")
        .onDisappear {
            operation?.cancel()
            removeFile()
        }
    }

    @MainActor private func prepare() async {
        guard let service else { return }
        busy = true
        failed = false
        removeFile()
        defer { busy = false }
        do {
            // Server reuses the active ticket after timeouts/reopening the screen.
            let requested = try await service.requestExport()
            try Task.checkCancellation()
            ticket = requested
            let downloaded = try await service.downloadExport(requested)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
                return
            }
            file = downloaded
        } catch is CancellationError { }
        catch { failed = true }
    }

    private func removeFile() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil
    }
}
