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
    @State private var model: ProfileModel
    @State private var showProfile = false

    init(dependencies: AppDependencies, accountID: UUID) {
        self.dependencies = dependencies
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
                AppRootView(dependencies: dependencies)
                    .safeAreaInset(edge: .top) {
                        Button("profile.title") { showProfile = true }.padding(8)
                    }
                    .sheet(isPresented: $showProfile) {
                        NavigationStack { ProfileEditorView(model: model) }
                    }
            }
        }
        .task { model.load() }
    }
}
