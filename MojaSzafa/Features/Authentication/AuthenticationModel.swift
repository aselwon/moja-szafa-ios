import Foundation
import Observation
import CryptoKit
import Security

@MainActor @Observable
final class AuthenticationModel {
    private(set) var session: AuthSession?
    private(set) var challenge: UUID?
    private(set) var busy = false
    private(set) var message: String?
    private(set) var restored = false
    private let service: any AuthenticationService
    private let store: any SessionStore
    private(set) var deletionPending = false
    private(set) var deletionChallengeID: UUID?
    private let deletionDefaults: UserDefaults
    private let clearAccountData: @MainActor (UUID) async throws -> Void
    private var generation = UUID()
    private var refreshTask: Task<AuthSession, Error>?
    private var pendingApple: (nonce: String, state: String, linking: Bool)?

    init(service: any AuthenticationService, store: any SessionStore,
         deletionDefaults: UserDefaults = .standard,
         clearAccountData: @escaping @MainActor (UUID) async throws -> Void = { try ProfileStore.local.remove(accountID: $0) }) {
        self.service = service
        self.store = store
        self.deletionDefaults = deletionDefaults
        self.clearAccountData = clearAccountData
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        do {
            session = try store.read()
            if let current = session {
                deletionPending = deletionDefaults.bool(forKey: deletionKey(current.userID, "submitted"))
            }
            if let current = session, deletionDefaults.bool(forKey: deletionKey(current.userID, "accepted")) {
                try await finishLocalDeletion(current.userID)
            } else if session != nil && !deletionPending { _ = try await accessToken() }
        } catch { show(error) }
    }

    func rejectSession(accessToken: String) {
        // A delayed 401 from a previous account must not clear a newer session.
        guard session?.accessToken == accessToken, !deletionPending else { return }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        message = "auth.expired"
        do { try store.clear() } catch { message = "auth.storage" }
    }

    func restoreOrRefresh() async {
        if !restored { await restore(); return }
        guard session != nil, !deletionPending else { return }
        do { _ = try await accessToken() } catch { show(error) }
    }

    func accessToken() async throws -> String {
        guard let current = session else { throw AuthError.expired }
        guard !deletionPending, !deletionDefaults.bool(forKey: deletionKey(current.userID, "accepted")) else { throw AuthError.expired }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let operation = generation
        let task: Task<AuthSession, Error>
        if let refreshTask { task = refreshTask }
        else {
            let service = service
            task = Task { try await service.refresh(current.refreshToken) }
            refreshTask = task
        }
        do {
            let renewed = try await task.value
            guard operation == generation else { throw AuthError.cancelled }
            guard renewed.userID == current.userID else { throw AuthError.invalidResponse }
            try save(renewed)
            refreshTask = nil
            return renewed.accessToken
        } catch {
            if operation == generation {
                refreshTask = nil
                if error as? AuthError == .expired {
                    session = nil
                    generation = UUID()
                    try store.clear()
                    message = "auth.expired"
                }
            }
            throw error
        }
    }

    func startEmail(_ email: String) async {
        guard !busy, session == nil else { return }
        busy = true
        defer { busy = false }
        let operation = generation
        do {
            let result = try await service.startEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
            guard operation == generation else { return }
            challenge = result
            message = "auth.sent"
        } catch { if operation == generation { show(error) } }
    }

    func verifyEmail(_ code: String) async {
        guard !busy, let challenge, session == nil else { return }
        busy = true
        defer { busy = false }
        let operation = generation
        do {
            let result = try await service.verifyEmail(challenge: challenge, code: code)
            guard operation == generation else { return }
            try save(result)
        } catch { if operation == generation { show(error) } }
    }

    /// Linking is armed only by the confirmation dialog; server must independently
    /// require proof of the new identity and a recent authenticated session.
    func prepareApple(linkingConfirmed: Bool) throws -> (nonceHash: String, state: String) {
        guard !busy, (session == nil || linkingConfirmed) else { throw AuthError.rejected }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AuthError.rejected }
        let nonce = Data(bytes).base64EncodedString()
        let state = UUID().uuidString
        pendingApple = (nonce, state, session != nil)
        busy = true
        return (SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined(), state)
    }

    func finishApple(identityToken: String, state: String?) async {
        guard let pending = pendingApple else { return }
        pendingApple = nil
        defer { busy = false }
        guard state == pending.state else { message = "auth.error"; return }
        let operation = generation
        let previousUser = session?.userID
        do {
            let bearer = pending.linking ? try await accessToken() : nil
            let result = try await service.apple(identityToken: identityToken, nonce: pending.nonce, linkingToken: bearer)
            guard operation == generation else { return }
            if pending.linking && result.userID != previousUser { throw AuthError.invalidResponse }
            try save(result)
        } catch { if operation == generation { show(error) } }
    }

    func cancelApple(failed: Bool = false) {
        pendingApple = nil
        busy = false
        if failed { message = "auth.error" }
    }
    func backToEmail() {
        guard !busy else { return }
        challenge = nil
        message = nil
    }
    func logout() async {
        let token = session?.refreshToken
        do {
            if deletionPending, let owner = session?.userID { try await clearAccountData(owner) }
            try store.clear()
        }
        catch { message = "auth.storage"; return }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        pendingApple = nil
        challenge = nil
        deletionChallengeID = nil
        deletionPending = false
        message = nil
        // Local logout is immediate, including offline. Server revocation may fail;
        // never restore a local session because of a network error.
        if let token {
            do { try await service.revoke(token) }
            catch { message = "auth.revocationPending" }
        }
    }
    private func deletionKey(_ owner: UUID, _ field: String) -> String { "deletion.\(owner.uuidString).\(field)" }

    private func deletionOperation(_ owner: UUID) -> UUID {
        let key = deletionKey(owner, "operation")
        if let text = deletionDefaults.string(forKey: key), let value = UUID(uuidString: text) { return value }
        let value = UUID()
        deletionDefaults.set(value.uuidString, forKey: key)
        return value
    }

    func startDeletion() async {
        guard !busy, let current = session else { return }
        busy = true
        defer { busy = false }
        let operation = generation
        do {
            if deletionDefaults.bool(forKey: deletionKey(current.userID, "accepted")) {
                try await finishLocalDeletion(current.userID)
                return
            }
            let bearer = current.accessToken
            let challenge = try await service.deletionChallenge(bearer: bearer, operationID: deletionOperation(current.userID))
            guard operation == generation else { return }
            deletionChallengeID = challenge
            message = "deletion.sent"
        } catch { if operation == generation { show(error) } }
    }

    func deleteAccount(code: String) async {
        guard !busy, let current = session, let challenge = deletionChallengeID, !code.isEmpty else { return }
        busy = true
        defer { busy = false }
        let operation = generation
        do {
            deletionDefaults.set(true, forKey: deletionKey(current.userID, "submitted"))
            deletionPending = true
            let bearer = current.accessToken
            _ = try await service.deleteAccount(bearer: bearer, operationID: deletionOperation(current.userID), challengeID: challenge, code: code)
            // Keep the local receipt across a crash or cleanup failure. Never claim
            // remote erasure is finished merely because the job was accepted.
            deletionDefaults.set(true, forKey: deletionKey(current.userID, "accepted"))
            guard operation == generation else { return }
            try await finishLocalDeletion(current.userID)
        } catch { if operation == generation { show(error) } }
    }

    private func finishLocalDeletion(_ owner: UUID) async throws {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        do {
            try await clearAccountData(owner)
            try store.clear()
        } catch { message = "deletion.cleanupError"; throw AuthError.storage }
        session = nil
        challenge = nil
        deletionChallengeID = nil
        pendingApple = nil
        message = "deletion.accepted"
    }

    private func save(_ value: AuthSession) throws {
        try value.validate()
        try store.write(value)
        session = value
        deletionPending = deletionDefaults.bool(forKey: deletionKey(value.userID, "submitted"))
        deletionChallengeID = nil
        challenge = nil
        message = nil
    }
    private func show(_ error: Error) {
        if error is CancellationError || error as? AuthError == .cancelled { return }
        if error as? AuthError == .notConfigured { message = "auth.unconfigured" }
        else if error as? AuthError == .expired { message = "auth.expired" }
        else if error as? AuthError == .storage { message = "auth.storage" }
        else if (error as? URLError)?.code == .notConnectedToInternet { message = "auth.offline" }
        else { message = "auth.error" }
    }
}
