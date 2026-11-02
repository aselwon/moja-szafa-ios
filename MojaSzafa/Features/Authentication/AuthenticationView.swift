import SwiftUI
import AuthenticationServices

struct AuthenticationView: View {
    @Bindable var model: AuthenticationModel
    @State private var email = ""
    @State private var code = ""
    @State private var confirmLink = false
    @State private var linkConfirmed = false
    @State private var deleting = false
    @State private var confirmDeletion = false

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
                    Button("deletion.title", role: .destructive) { confirmDeletion = true }.disabled(model.busy)
                    if deleting {
                        Text("deletion.reauthenticate")
                        Link("deletion.subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                        Button("deletion.email") { Task { await model.startDeletionEmail() } }.disabled(model.busy)
                        if model.deletionChallenge != nil {
                            SecureField("auth.code", text: $code).textContentType(.oneTimeCode)
                            Button("deletion.confirm", role: .destructive) {
                                Task { await model.deleteWithEmail(code: code); code = "" }
                            }.disabled(code.isEmpty || model.busy)
                        }
                        appleButton
                        Button("auth.cancel", role: .cancel) { deleting = false; code = "" }.disabled(model.busy)
                    }
                    if linkConfirmed && !deleting { appleButton }
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
        .confirmationDialog("deletion.title", isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button("deletion.confirm", role: .destructive) { deleting = true; linkConfirmed = false }
            Button("auth.cancel", role: .cancel) {}
        } message: { Text("deletion.explanation") }
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
                let challenge = try model.prepareApple(linkingConfirmed: linkConfirmed, deleting: deleting)
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
                Task { await model.finishApple(identityToken: token, state: credential.state,
                    authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }) }
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
    let dependencies: AppDependencies
    @State private var model: AuthenticationModel
    @State private var showAccount = false
    @AppStorage("welcome.seen.v1") private var welcomeSeen = false
    @Environment(\.scenePhase) private var scenePhase

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _model = State(initialValue: AuthenticationModel(
            service: dependencies.authentication,
            store: KeychainSessionStore(service: Bundle.main.bundleIdentifier ?? "pl.mojaszafa.app")))
    }

    var body: some View {
        Group {
            if !welcomeSeen {
                WelcomeView { welcomeSeen = true }
            } else if !model.restored {
                ProgressView().accessibilityLabel(Text("auth.loading"))
            } else if model.deletionPendingCleanup {
                VStack {
                    Text("deletion.cleanup")
                    Button("profile.retry") { Task { await model.restoreOrRefresh() } }
                }
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
        .task {
            model.deletionCleanup = { _ in try await dependencies.offline?.invalidateAccount() }
            await model.restore()
        }
        .onChange(of: model.session?.userID) { _, _ in showAccount = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restoreOrRefresh() } }
        }
    }
}
