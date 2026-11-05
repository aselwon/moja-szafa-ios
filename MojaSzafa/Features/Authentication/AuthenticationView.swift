import SwiftUI
import AuthenticationServices

struct AuthenticationView: View {
    @Bindable var model: AuthenticationModel
    @State private var email = ""
    @State private var code = ""
    @State private var confirmLink = false
    @State private var linkConfirmed = false

    var body: some View {
        Form {
            if model.session == nil {
                Section {
                    Text("auth.intro")
                    if model.challenge == nil {
                        TextField("auth.email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("auth.send") { Task { await model.startEmail(email) } }
                            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    } else {
                        TextField("auth.code", text: $code)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                        Button("auth.verify") { Task { await model.verifyEmail(code); code = "" } }
                            .disabled(code.isEmpty || model.busy)
                        Button("auth.back") { model.backToEmail(); code = "" }
                            .disabled(model.busy)
                    }
                }
                Section { appleButton }
            } else {
                Section {
                    Text("auth.signedIn")
                    if linkConfirmed { appleButton }
                    else { Button("auth.link") { confirmLink = true }.disabled(model.busy) }
                    Button("auth.logout", role: .destructive) {
                        Task { await model.logout(); linkConfirmed = false }
                    }.disabled(model.busy)
                }
            }
            if model.busy { ProgressView().accessibilityLabel(Text("auth.loading")) }
            if let message = model.message {
                Text(LocalizedStringKey(message))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .navigationTitle("auth.title")
        .confirmationDialog("auth.linkTitle", isPresented: $confirmLink, titleVisibility: .visible) {
            Button("auth.linkConfirm") { linkConfirmed = true }
            Button("auth.cancel", role: .cancel) {}
        } message: {
            Text("auth.linkExplanation")
        }
    }

    private var appleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            do {
                let challenge = try model.prepareApple(linkingConfirmed: linkConfirmed)
                request.requestedScopes = [.email]
                request.nonce = challenge.nonceHash
                request.state = challenge.state
            } catch { model.cancelApple(failed: true) }
        } onCompletion: { result in
            linkConfirmed = false
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken,
                      let token = String(data: data, encoding: .utf8) else {
                    model.cancelApple(failed: true)
                    return
                }
                // Apple may omit email on subsequent authorizations. Neither it nor
                // the private relay address is used for local identity matching.
                Task { await model.finishApple(identityToken: token, state: credential.state) }
            case .failure(let error):
                model.cancelApple(failed: (error as? ASAuthorizationError)?.code != .canceled)
            }
        }
        .frame(minHeight: 50)
        .disabled(model.busy)
        .accessibilityLabel(Text("auth.apple"))
    }
}

struct AuthenticationGateView: View {
    @EnvironmentObject private var reminders: ReminderModel
    @EnvironmentObject private var widget: WardrobeWidgetModel
    let dependencies: AppDependencies
    @State private var model: AuthenticationModel
    @State private var showAccount = false
    @AppStorage("welcome.seen.v1") private var welcomeSeen = false
    @Environment(\.scenePhase) private var scenePhase

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: AuthenticationModel(
            service: dependencies.authentication,
            store: KeychainSessionStore(service: dependencies.sessionStoreService)))
    }

    var body: some View {
        Group {
            if !welcomeSeen {
                WelcomeView { welcomeSeen = true }
            } else if !model.restored {
                ProgressView().accessibilityLabel(Text("auth.loading"))
            } else if let session = model.session {
                ProfileGateView(dependencies: dependencies.authenticated(using: model), accountID: session.userID)
                    .id(session.userID)
                    .safeAreaInset(edge: .top) {
                        Button("auth.account") { showAccount = true }
                            .padding(8)
                    }
                    .sheet(isPresented: $showAccount) {
                        NavigationStack {
                            AuthenticationView(model: model)
                                .toolbar { Button("auth.close") { showAccount = false } }
                        }
                    }
            } else {
                NavigationStack { AuthenticationView(model: model) }
            }
        }
        .task { await model.restore(); updateReminders() }
        .onChange(of: model.session?.userID) { _, _ in showAccount = false; updateReminders() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restoreOrRefresh(); updateReminders(); await reminders.refresh(); await widget.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: WearIntentRoute.notification)) { _ in
            showAccount = false; widget.consumeIntent()
        }
        .onOpenURL { url in
            guard let scheme = Bundle.main.object(forInfoDictionaryKey: "AppURLScheme") as? String else { return }
            widget.open(url, expectedScheme: scheme)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            Task { await reminders.refresh(); await widget.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            Task { await reminders.refresh(); await widget.refresh() }
        }
    }
    private func updateReminders() {
        let authenticated = dependencies.authenticated(using: model)
        reminders.sessionChanged(accountID: model.session?.userID, gateway: dependencies.sessionStoreService,
            repository: authenticated.planner)
        widget.sessionChanged(accountID: model.session?.userID, gateway: dependencies.sessionStoreService,
            repository: authenticated.planner)
    }
}
