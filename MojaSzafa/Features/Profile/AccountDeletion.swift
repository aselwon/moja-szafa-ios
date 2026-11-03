import SwiftUI
import Observation
import AuthenticationServices

struct DeletionChallenge: Codable, Sendable {
    let id: UUID
    let method: String
    let nonce: String?
    let state: String?
}

protocol AccountDeletionService: Sendable {
    func challenge() async throws -> DeletionChallenge
    func delete(operationID: UUID, proof: [String: String]) async throws
}

struct AccountDeletionClient: AccountDeletionService {
    let baseURL: URL
    let transport: any APITransport
    let accessToken: @Sendable () async throws -> String

    private func call(_ path: String, body: Data?) async throws -> Data {
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw AuthError.expired }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/account/deletion" + path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.send(request)
        guard response.statusCode == (path.isEmpty ? 202 : 200) else { throw AuthError.rejected }
        return data
    }
    func challenge() async throws -> DeletionChallenge {
        let data = try await call("/challenge", body: nil)
        let value = try JSONDecoder().decode(DeletionChallenge.self, from: data)
        guard value.method == "email" || (value.method == "apple" && value.nonce?.isEmpty == false && value.state?.isEmpty == false)
        else { throw AuthError.invalidResponse }
        return value
    }
    func delete(operationID: UUID, proof: [String: String]) async throws {
        struct Body: Encodable { let operation_id: UUID; let proof: [String: String] }
        struct Receipt: Decodable { let id: UUID; let status: String }
        let data = try await call("", body: JSONEncoder().encode(Body(operation_id: operationID, proof: proof)))
        guard try JSONDecoder().decode(Receipt.self, from: data).status == "accepted" else { throw AuthError.invalidResponse }
    }
}

@MainActor @Observable
final class AccountDeletionModel {
    private(set) var challenge: DeletionChallenge?
    private(set) var busy = false
    private(set) var accepted = false
    private(set) var message: String?
    let operationID: UUID
    private let service: (any AccountDeletionService)?
    private let cleanup: @MainActor () async throws -> Void

    init(service: (any AccountDeletionService)?, operationID: UUID,
         cleanup: @escaping @MainActor () async throws -> Void) {
        self.service = service
        self.operationID = operationID
        self.cleanup = cleanup
    }
    func begin() async {
        guard !busy, !accepted else { return }
        guard let service else { message = "deletion.unconfigured"; return }
        busy = true
        defer { busy = false }
        do { challenge = try await service.challenge(); message = nil }
        catch { message = "deletion.error" }
    }
    func submit(_ proof: [String: String]) async {
        guard !busy else { return }
        guard let service else { message = "deletion.unconfigured"; return }
        busy = true
        defer { busy = false }
        do {
            if !accepted {
                guard let challenge else { return }
                var boundProof = proof
                boundProof["challenge_id"] = challenge.id.uuidString.lowercased()
                try await service.delete(operationID: operationID, proof: boundProof)
                accepted = true
                self.challenge = nil
            }
            // Failure here must not resubmit the remote deletion or claim success.
            try await cleanup()
            message = "deletion.accepted"
        } catch { message = accepted ? "deletion.cleanupError" : "deletion.error" }
    }
}

struct AccountDeletionView: View {
    @State private var model: AccountDeletionModel
    @State private var code = ""
    @State private var confirm = false

    init(service: (any AccountDeletionService)?, accountID: UUID,
         cleanup: @escaping @MainActor () async throws -> Void) {
        // One deletion per account server-side; stable across navigation/relaunch.
        _model = State(initialValue: AccountDeletionModel(service: service, operationID: accountID, cleanup: cleanup))
    }
    var body: some View {
        Form {
            Section {
                Text("deletion.consequences")
                Text("deletion.subscription")
                Link("deletion.manage", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                Text("deletion.backups")
            }
            if model.accepted {
                Button("profile.retry") { Task { await model.submit([:]) } }.disabled(model.busy)
            } else if let challenge = model.challenge {
                Text("deletion.reauthenticate")
                if challenge.method == "email" {
                    SecureField("auth.code", text: $code).textContentType(.oneTimeCode).keyboardType(.numberPad)
                    Button("deletion.confirm", role: .destructive) {
                        let proof = code
                        code = ""
                        Task { await model.submit(["code": proof]) }
                    }.disabled(model.busy || code.isEmpty)
                } else {
                    SignInWithAppleButton(.continue) { request in
                        request.nonce = challenge.nonce
                        request.state = challenge.state
                    } onCompletion: { result in
                        guard case .success(let authorization) = result,
                              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                              credential.state == challenge.state,
                              let token = credential.identityToken, let authorizationCode = credential.authorizationCode,
                              let tokenString = String(data: token, encoding: .utf8),
                              let codeString = String(data: authorizationCode, encoding: .utf8) else { return }
                        Task { await model.submit(["identity_token": tokenString, "authorization_code": codeString,
                                                  "state": credential.state ?? ""]) }
                    }.frame(minHeight: 50).disabled(model.busy)
                }
                Button("deletion.restart") { Task { await model.begin() } }.disabled(model.busy)
            } else {
                Button("deletion.title", role: .destructive) { confirm = true }.disabled(model.busy)
            }
            if model.busy { ProgressView() }
            if let message = model.message { Text(LocalizedStringKey(message)) }
        }
        .navigationTitle("deletion.title")
        .confirmationDialog("deletion.title", isPresented: $confirm, titleVisibility: .visible) {
            Button("deletion.continue", role: .destructive) { Task { await model.begin() } }
            Button("auth.cancel", role: .cancel) {}
        } message: { Text("deletion.consequences") }
    }
}
