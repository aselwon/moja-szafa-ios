import XCTest
@testable import MojaSzafa

@MainActor
final class AuthenticationTests: XCTestCase {
    func testDeletionClientSendsPurposeProofAndStableOperation() async throws {
        let transport = AuthTransport(status: 200, data: Data("{\"jobID\":\"00000000-0000-0000-0000-000000000017\",\"status\":\"queued\"}".utf8))
        let client = try AuthenticationClient(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        let operation = UUID()
        try await client.deleteAccount(bearer: "synthetic", operationID: operation,
                                       proof: ["method": "email", "code": "123456"])
        let request = await transport.lastRequest
        XCTAssertEqual(request?.url?.path, "/auth/v1/deletion")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
        let body = try XCTUnwrap(request?.httpBody)
        let json = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(json["operationID"], operation.uuidString)
        XCTAssertEqual(json["method"], "email")
    }

    func testDeletionAcceptanceClearsLocalSessionAndRunsCleanup() async {
        let store = MemorySessionStore(value: makeSession())
        let service = AuthStub()
        let model = AuthenticationModel(service: service, store: store)
        var cleaned = false
        model.deletionCleanup = { _ in cleaned = true }
        await model.restore()
        await model.startDeletionEmail()
        await model.deleteWithEmail(code: "123456")
        XCTAssertTrue(cleaned)
        XCTAssertNil(store.value)
        XCTAssertNil(model.session)
        XCTAssertEqual(model.message, "deletion.accepted")
    }

    func testUnconfiguredDeletionPreservesSession() async {
        let store = MemorySessionStore(value: makeSession())
        let model = AuthenticationModel(service: UnconfiguredAuthenticationService(), store: store)
        await model.restore()
        await model.startDeletionEmail()
        XCTAssertNotNil(model.session)
        XCTAssertNil(model.deletionChallenge)
        XCTAssertEqual(model.message, "auth.unconfigured")
    }

    func testAcceptedDeletionRetriesLocalCleanupWithoutServerOrRefresh() async {
        let current = makeSession()
        let store = MemorySessionStore(value: current)
        let model = AuthenticationModel(service: AuthStub(), store: store)
        model.deletionCleanup = { _ in throw AuthError.storage }
        await model.restore()
        await model.startDeletionEmail()
        await model.deleteWithEmail(code: "123456")
        XCTAssertEqual(model.message, "auth.storage")
        let restored = AuthenticationModel(service: UnconfiguredAuthenticationService(), store: store)
        await restored.restore()
        XCTAssertNil(restored.session)
        XCTAssertNil(store.value)
    }

    func testEmailChallengeAndSessionArePersisted() async {
        let store = MemorySessionStore()
        let service = AuthStub()
        let model = AuthenticationModel(service: service, store: store)
        await model.startEmail(" person@example.invalid ")
        XCTAssertNotNil(model.challenge)
        await model.verifyEmail("123456")
        XCTAssertEqual(model.session, store.value)
        XCTAssertNotNil(model.session)
        XCTAssertNil(model.challenge)
    }

    func testAppleRequiresStateAndConsumesAttempt() async throws {
        let service = AuthStub()
        let model = AuthenticationModel(service: service, store: MemorySessionStore())
        let first = try model.prepareApple(linkingConfirmed: false)
        XCTAssertEqual(first.nonceHash.count, 64)
        await model.finishApple(identityToken: "synthetic", state: "wrong")
        await model.finishApple(identityToken: "synthetic", state: first.state)
        let count = await service.appleCalls
        XCTAssertEqual(count, 0)
        XCTAssertNil(model.session)
        let next = try model.prepareApple(linkingConfirmed: false)
        XCTAssertNotEqual(first.nonceHash, next.nonceHash)
    }

    func testAppleDoesNotRequireEmailIncludingRelayAndRepeatLogin() async throws {
        let model = AuthenticationModel(service: AuthStub(), store: MemorySessionStore())
        for _ in 0..<2 {
            let challenge = try model.prepareApple(linkingConfirmed: false)
            await model.finishApple(identityToken: "synthetic", state: challenge.state)
            XCTAssertNotNil(model.session)
            await model.logout()
            XCTAssertNil(model.session)
        }
    }

    func testLinkRequiresConfirmationAndCannotSwitchAccount() async throws {
        let store = MemorySessionStore(value: makeSession())
        let original = store.value
        let service = AuthStub() // Returns a different user: linking must reject it.
        let model = AuthenticationModel(service: service, store: store)
        await model.restore()
        XCTAssertThrowsError(try model.prepareApple(linkingConfirmed: false))
        let challenge = try model.prepareApple(linkingConfirmed: true)
        await model.finishApple(identityToken: "synthetic", state: challenge.state)
        XCTAssertEqual(model.session, original)
        XCTAssertEqual(store.value, original)
        XCTAssertEqual(model.message, "auth.error")
        let bearer = await service.linkingToken
        XCTAssertEqual(bearer, original?.accessToken)
    }

    func testExpiredRefreshClearsSessionAndKeychain() async {
        let store = MemorySessionStore(value: makeSession(expiry: -10))
        let model = AuthenticationModel(service: AuthStub(refreshError: .expired), store: store)
        await model.restore()
        XCTAssertNil(model.session)
        XCTAssertNil(store.value)
        XCTAssertEqual(model.message, "auth.expired")
    }

    func testTransientRefreshFailurePreservesCredentialsForRetry() async {
        let store = MemorySessionStore(value: makeSession(expiry: -10))
        let original = store.value
        let model = AuthenticationModel(service: AuthStub(refreshError: .rejected), store: store)
        await model.restore()
        XCTAssertEqual(store.value, original)
        XCTAssertEqual(model.session, original)
    }

    func testRefreshRotatesCredentialsForSameUser() async {
        let old = makeSession(expiry: -10)
        let store = MemorySessionStore(value: old)
        let renewed = makeSession(user: old.userID)
        let model = AuthenticationModel(service: AuthStub(result: renewed), store: store)
        await model.restore()
        XCTAssertEqual(model.session, renewed)
        XCTAssertEqual(store.value, renewed)
    }

    func testStorageFailureDoesNotAuthenticate() async {
        let store = MemorySessionStore()
        store.failWrites = true
        let model = AuthenticationModel(service: AuthStub(), store: store)
        await model.startEmail("person@example.invalid")
        await model.verifyEmail("123456")
        XCTAssertNil(model.session)
        XCTAssertEqual(model.message, "auth.storage")
    }

    func testLogoutCannotBeUndoneByLateLoginResponse() async {
        let service = SuspendedAuth()
        let store = MemorySessionStore()
        let model = AuthenticationModel(service: service, store: store)
        await model.startEmail("person@example.invalid")
        let login = Task { await model.verifyEmail("123456") }
        await service.waitForVerification()
        await model.logout()
        await service.finish()
        await login.value
        XCTAssertNil(model.session)
        XCTAssertNil(store.value)
    }

    func testResourceAPI401ClearsOnlyTheRejectedSession() async throws {
        let original = makeSession()
        let store = MemorySessionStore(value: original)
        let model = AuthenticationModel(service: AuthStub(), store: store)
        await model.restore()
        model.rejectSession(accessToken: "old-session")
        XCTAssertEqual(model.session, original)
        let client = try APIClient(
            baseURL: URL(string: "https://example.invalid")!,
            transport: AuthTransport(status: 401, data: Data()),
            unauthorized: { token in await model.rejectSession(accessToken: token) },
            accessToken: { try await model.accessToken() })
        do { _ = try await client.garments(); XCTFail("401 must fail") } catch {}
        XCTAssertNil(model.session)
        XCTAssertNil(store.value)
        XCTAssertEqual(model.message, "auth.expired")
    }

    func testLateRefreshCannotRestoreLoggedOutSession() async {
        let store = MemorySessionStore(value: makeSession(expiry: -10))
        let service = SuspendedRefresh(userID: store.value!.userID)
        let model = AuthenticationModel(service: service, store: store)
        let restore = Task { await model.restore() }
        await service.waitForRefresh()
        await model.logout()
        await service.finish()
        await restore.value
        XCTAssertNil(model.session)
        XCTAssertNil(store.value)
    }

    func testClientContractAnd401() async throws {
        let transport = AuthTransport(status: 401, data: Data())
        let client = try AuthenticationClient(baseURL: URL(string: "https://auth.example.invalid")!, transport: transport)
        do {
            _ = try await client.apple(identityToken: "synthetic", nonce: "nonce", linkingToken: "session")
            XCTFail("401 must fail")
        } catch { XCTAssertEqual(error as? AuthError, .expired) }
        let request = await transport.lastRequest
        XCTAssertEqual(request?.url?.path, "/auth/v1/identities/apple")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer session")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["identityToken": "synthetic", "nonce": "nonce"])
    }

    func testClientRejectsMalformedSessionAndInsecureEndpoint() async throws {
        XCTAssertThrowsError(try AuthenticationClient(baseURL: URL(string: "http://example.invalid")!, transport: AuthTransport(status: 200, data: Data())))
        let transport = AuthTransport(status: 200, data: Data("{}".utf8))
        let client = try AuthenticationClient(baseURL: URL(string: "https://example.invalid")!, transport: transport)
        do { _ = try await client.refresh("synthetic"); XCTFail("Malformed session must fail") }
        catch { XCTAssertEqual(error as? AuthError, .invalidResponse) }
    }
}

private func makeSession(user: UUID = UUID(), expiry: TimeInterval = 3600) -> AuthSession {
    AuthSession(userID: user, accessToken: "test-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(expiry))
}

@MainActor
private final class MemorySessionStore: SessionStore {
    var value: AuthSession?
    var failWrites = false
    init(value: AuthSession? = nil) { self.value = value }
    func read() throws -> AuthSession? { value }
    func write(_ session: AuthSession) throws {
        if failWrites { throw AuthError.storage }
        value = session
    }
    func clear() throws { value = nil }
}

private actor AuthStub: AuthenticationService {
    let result: AuthSession
    let refreshError: AuthError?
    private(set) var appleCalls = 0
    private(set) var linkingToken: String?
    init(result: AuthSession = makeSession(), refreshError: AuthError? = nil) {
        self.result = result
        self.refreshError = refreshError
    }
    func deletionChallenge(bearer: String) async throws -> UUID { UUID() }
    func deleteAccount(bearer: String, operationID: UUID, proof: [String: String]) async throws {}
    func startEmail(_ email: String) async throws -> UUID { UUID() }
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession { result }
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession {
        appleCalls += 1
        self.linkingToken = linkingToken
        return result
    }
    func refresh(_ token: String) async throws -> AuthSession {
        if let refreshError { throw refreshError }
        return result
    }
    func revoke(_ token: String) async throws {}
}

private actor SuspendedAuth: AuthenticationService {
    private var pending: CheckedContinuation<AuthSession, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func startEmail(_ email: String) async throws -> UUID { UUID() }
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func waitForVerification() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(returning: makeSession()); pending = nil }
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession { throw AuthError.rejected }
    func refresh(_ token: String) async throws -> AuthSession { throw AuthError.rejected }
    func revoke(_ token: String) async throws {}
}

private actor AuthTransport: APITransport {
    let status: Int
    let data: Data
    private(set) var lastRequest: URLRequest?
    init(status: Int, data: Data) { self.status = status; self.data = data }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SuspendedRefresh: AuthenticationService {
    let userID: UUID
    private var pending: CheckedContinuation<AuthSession, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(userID: UUID) { self.userID = userID }
    func refresh(_ token: String) async throws -> AuthSession {
        await withCheckedContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func waitForRefresh() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(returning: makeSession(user: userID)); pending = nil }
    func startEmail(_ email: String) async throws -> UUID { throw AuthError.rejected }
    func verifyEmail(challenge: UUID, code: String) async throws -> AuthSession { throw AuthError.rejected }
    func apple(identityToken: String, nonce: String, linkingToken: String?) async throws -> AuthSession { throw AuthError.rejected }
    func revoke(_ token: String) async throws {}
}
