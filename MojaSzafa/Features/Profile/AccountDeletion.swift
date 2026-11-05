import SwiftUI
import Observation
import AuthenticationServices

struct DeletionChallenge: Codable, Sendable {
    let id: UUID
    let method: String
    let nonce: String?
    let state: String?
    var receiptToken: String? = nil
}

protocol AccountDeletionService: Sendable {
    func challenge() async throws -> DeletionChallenge
    func delete(operationID: UUID, proof: [String: String]) async throws
    func receipt(operationID: UUID, challengeID: UUID, token: String?) async throws -> Bool
}

extension AccountDeletionService {
    func receipt(operationID: UUID, challengeID: UUID, token: String?) async throws -> Bool { false }
}

struct AccountDeletionClient: AccountDeletionService {
    let baseURL: URL
    let transport: any APITransport
    let accessToken: @Sendable () async throws -> String

    private func call(_ path: String, body: Data?, requiresSession: Bool = true) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/account/deletion" + path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        if requiresSession {
            let token = try await accessToken()
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw AuthError.expired }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.send(request)
        guard response.statusCode == (path.isEmpty ? 202 : 200) else { throw AuthError.rejected }
        return data
    }
    func receipt(operationID: UUID, challengeID: UUID, token: String?) async throws -> Bool {
        struct Body: Encodable { let operation_id: UUID; let challenge_id: UUID; let receipt_token: String? }
        struct Receipt: Decodable { let accepted: Bool }
        let data = try await call("/status", body: JSONEncoder().encode(Body(operation_id: operationID, challenge_id: challengeID, receipt_token: token)), requiresSession: token == nil)
        return try JSONDecoder().decode(Receipt.self, from: data).accepted
    }
    func challenge() async throws -> DeletionChallenge {
        let data = try await call("/challenge", body: nil)
        let value = try JSONDecoder().decode(DeletionChallenge.self, from: data)
        guard value.method == "email" || (value.method == "apple" && value.nonce?.isEmpty == false && value.state?.isEmpty == false)
        else { throw AuthError.invalidResponse }
        if let token = value.receiptToken, token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) == nil { throw AuthError.invalidResponse }
        return value
    }
    func delete(operationID: UUID, proof: [String: String]) async throws {
        struct Body: Encodable { let operation_id: UUID; let proof: [String: String] }
        struct Receipt: Decodable { let id: UUID; let status: String }
        let data = try await call("", body: JSONEncoder().encode(Body(operation_id: operationID, proof: proof)))
        guard try JSONDecoder().decode(Receipt.self, from: data).status == "accepted" else { throw AuthError.invalidResponse }
    }
}

/// Stores deletion progress and its read-only receipt capability, never an OTP or login session token.
struct DeletionProgress: Codable {
    let operationID: UUID
    let challenge: DeletionChallenge?
    let accepted: Bool

    func write(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = parent
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read(from url: URL, operationID: UUID) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16384 else { throw AuthError.storage }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.operationID == operationID else { throw AuthError.storage }
        return result
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
    private let journalURL: URL?
    private var recoveryUnavailable = false

    init(service: (any AccountDeletionService)?, operationID: UUID, journalURL: URL? = nil,
         cleanup: @escaping @MainActor () async throws -> Void) {
        self.service = service
        self.operationID = operationID
        self.cleanup = cleanup
        self.journalURL = journalURL
        if let journalURL {
            do {
                if let progress = try DeletionProgress.read(from: journalURL, operationID: operationID) {
                    challenge = progress.challenge; accepted = progress.accepted
                }
            } catch { recoveryUnavailable = true; message = "deletion.cleanupError" }
        }
    }
    private func persist() throws {
        if let journalURL { try DeletionProgress(operationID: operationID, challenge: challenge, accepted: accepted).write(to: journalURL) }
    }
    private func finishLocal() async throws {
        try persist()
        try await cleanup()
        if let journalURL, FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
        message = "deletion.accepted"
    }
    func resume() async {
        guard !busy, !recoveryUnavailable else { return }
        busy = true; defer { busy = false }
        do {
            if !accepted, let challenge, let service {
                accepted = try await service.receipt(operationID: operationID, challengeID: challenge.id, token: challenge.receiptToken)
                if accepted { self.challenge = nil }
            }
            if accepted { try await finishLocal() }
        } catch { message = accepted ? "deletion.cleanupError" : "deletion.error" }
    }
    func begin() async {
        guard !busy, !accepted, !recoveryUnavailable else { return }
        guard let service else { message = "deletion.unconfigured"; return }
        busy = true
        defer { busy = false }
        do { challenge = try await service.challenge(); try persist(); message = nil }
        catch { message = "deletion.error" }
    }
    func submit(_ proof: [String: String]) async {
        guard !busy, !recoveryUnavailable else { return }
        guard let service else { message = "deletion.unconfigured"; return }
        busy = true
        defer { busy = false }
        do {
            if !accepted {
                guard let challenge else { return }
                var boundProof = proof
                boundProof["challenge_id"] = challenge.id.uuidString.lowercased()
                try persist() // Never send a destructive request without its durable challenge.
                try await service.delete(operationID: operationID, proof: boundProof)
                accepted = true
                self.challenge = nil
            }
            // Failure here must not resubmit the remote deletion or claim success.
            try await finishLocal()
        } catch { message = accepted ? "deletion.cleanupError" : "deletion.error" }
    }
}

struct AccountDeletionView: View {
    @State private var model: AccountDeletionModel
    @State private var code = ""
    @State private var confirm = false

    init(service: (any AccountDeletionService)?, accountID: UUID, journalURL: URL? = nil,
         cleanup: @escaping @MainActor () async throws -> Void) {
        // One deletion per account server-side; stable across navigation/relaunch.
        _model = State(initialValue: AccountDeletionModel(service: service, operationID: accountID, journalURL: journalURL, cleanup: cleanup))
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
        .task { await model.resume() }
        .confirmationDialog("deletion.title", isPresented: $confirm, titleVisibility: .visible) {
            Button("deletion.continue", role: .destructive) { Task { await model.begin() } }
            Button("auth.cancel", role: .cancel) {}
        } message: { Text("deletion.consequences") }
    }
}
