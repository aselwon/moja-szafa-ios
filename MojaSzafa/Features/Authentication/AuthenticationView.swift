import SwiftUI
import AuthenticationServices

struct AuthenticationView: View {
    @Bindable var model: AuthenticationModel
    var allowsAccountActions = true
    @State private var showDeletion = false
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
            } else if allowsAccountActions {
                Section {
                    Text("auth.signedIn")
                    Button("deletion.title", role: .destructive) { showDeletion = true }
                        .disabled(model.busy)
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
        .sheet(isPresented: $showDeletion) {
            NavigationStack { AccountDeletionView(model: model) }
        }
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
                let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                Task { await model.finishApple(identityToken: token, state: credential.state, authorizationCode: authorizationCode) }
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
            store: KeychainSessionStore(service: Bundle.main.bundleIdentifier ?? "pl.mojaszafa.app"),
            deletionCleanup: { accountID in
                try await dependencies.offline?.invalidateAccount()
                try PhotoImportModel.deleteDrafts(directory: PhotoImportModel.directory(for: accountID))
            }))
    }

    var body: some View {
        Group {
            if !welcomeSeen {
                WelcomeView { welcomeSeen = true }
            } else if !model.restored {
                ProgressView().accessibilityLabel(Text("auth.loading"))
            } else if model.deletionCleanupPending {
                VStack {
                    Text("deletion.cleanupRetry")
                    Button("deletion.retryCleanup") { Task { await model.finishAcceptedDeletion() } }
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
        .task { await model.restore() }
        .onChange(of: model.session?.userID) { _, _ in showAccount = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.restoreOrRefresh() } }
        }
    }
}

struct AccountDeletionView: View {
    @Bindable var model: AuthenticationModel
    @State private var reauthentication: AuthenticationModel
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss
    private let operationID: UUID

    init(model: AuthenticationModel) {
        self.model = model
        _reauthentication = State(initialValue: model.deletionAuthentication())
        let key = "deletion.operation.\(model.session?.userID.uuidString ?? "unknown")"
        let id = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        operationID = id
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Text("deletion.explanation")
                Link("deletion.subscriptions", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            .frame(maxHeight: 200)
            .padding(.horizontal)
            if reauthentication.session == nil {
                AuthenticationView(model: reauthentication, allowsAccountActions: false)
            } else {
                Form {
                    Text("deletion.confirmExplanation")
                    Button("deletion.confirm", role: .destructive) { confirm = true }
                        .disabled(model.busy)
                    Button("deletion.retryIdentity") { Task { await reauthentication.logout() } }
                        .disabled(model.busy)
                    if model.busy { ProgressView() }
                    if let message = model.message { Text(LocalizedStringKey(message)) }
                }
            }
        }
        .navigationTitle("deletion.title")
        .toolbar { Button("common.cancel") { dismiss() }.disabled(model.busy) }
        .interactiveDismissDisabled(model.busy)
        .confirmationDialog("deletion.confirm", isPresented: $confirm, titleVisibility: .visible) {
            Button("deletion.confirm", role: .destructive) {
                Task {
                    if await model.deleteAccount(reauthenticated: reauthentication, operationID: operationID) { dismiss() }
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: { Text("deletion.confirmExplanation") }
    }
}
