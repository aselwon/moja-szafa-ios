import Foundation

struct AuthSession: Codable, Sendable, Equatable {
    let userID: UUID
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    func validate() throws {
        guard !accessToken.isEmpty, !refreshToken.isEmpty,
              !accessToken.contains(where: { $0.isWhitespace }),
              !refreshToken.contains(where: { $0.isWhitespace }),
              expiresAt > Date() else { throw AuthError.invalidResponse }
    }
}

enum AuthError: Error, Equatable {
    case notConfigured, expired, invalidResponse, rejected, storage, cancelled
}

/// The gateway must enforce identity ownership; email is never an account key.
/// This is deliberately NOT a direct Supabase Auth adapter (see T013 runbook).
protocol AuthenticationService: Sendable {
    func startEmail(_ email: String) async throws -> UUID
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession
    func refresh(_ token: String) async throws -> AuthSession
    func revoke(_ token: String) async throws
}

struct UnconfiguredAuthenticationService: AuthenticationService {
    func startEmail(_ email: String) async throws -> UUID { throw AuthError.notConfigured }
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession { throw AuthError.notConfigured }
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession { throw AuthError.notConfigured }
    func refresh(_ token: String) async throws -> AuthSession { throw AuthError.notConfigured }
    func revoke(_ token: String) async throws { throw AuthError.notConfigured }
}

struct AuthenticationClient: AuthenticationService {
    let baseURL: URL
    let transport: any APITransport

    init(baseURL: URL, transport: any APITransport) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw APIClientError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    private struct Challenge: Decodable, Sendable { let challengeID: UUID }
    private struct Empty: Decodable, Sendable {}
    private struct Failure: Decodable { let error: APIv1.Failure }

    func startEmail(_ email: String) async throws -> UUID {
        let result: Challenge = try await call("email/start", body: ["email": email])
        return result.challengeID
    }
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession {
        try await session("email/verify", body: ["challengeID": challenge.uuidString, "code": code])
    }
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession {
        try await session(linkingToken == nil ? "apple" : "identities/apple", body: [
            "identityToken": identityToken, "nonce": nonce
        ], bearer: linkingToken)
    }
    func refresh(_ token: String) async throws -> AuthSession {
        try await session("refresh", body: ["refreshToken": token])
    }
    func revoke(_ token: String) async throws {
        let _: Empty = try await call("logout", body: ["refreshToken": token])
    }
    private func session(_ path: String, body: [String: String], bearer: String? = nil) async throws -> AuthSession {
        let result: AuthSession = try await call(path, body: body, bearer: bearer)
        try result.validate()
        return result
    }
    private func call<T: Decodable & Sendable>(_ path: String, body: [String: String], bearer: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/v1").appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer {
            guard !bearer.isEmpty, !bearer.contains(where: { $0.isWhitespace }) else { throw AuthError.expired }
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 401 { throw AuthError.expired }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard (200...299).contains(response.statusCode) else {
            if let failure = try? decoder.decode(Failure.self, from: data) { throw failure.error }
            throw AuthError.rejected
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AuthError.invalidResponse }
    }
}
