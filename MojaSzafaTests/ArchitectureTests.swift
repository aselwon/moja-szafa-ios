import XCTest
import UIKit
@testable import MojaSzafa

#if DEBUG
@MainActor
final class DemoModeTests: XCTestCase {
    func testDemoRequiresExplicitLaunchArgument() {
        XCTAssertFalse(DemoMode.isEnabled(arguments: ["MojaSzafa"]))
        XCTAssertFalse(DemoMode.isEnabled(arguments: ["MojaSzafa", "--demo=false"]))
        XCTAssertTrue(DemoMode.isEnabled(arguments: ["MojaSzafa", "--demo"]))
    }

    func testDemoDataAndEditsAreLocalToOneInstance() async throws {
        let repository = DemoWardrobe.make()
        let initial = try await repository.garments()
        XCTAssertEqual(initial.count, 6)
        let first = try XCTUnwrap(initial.first)
        let bytes = try await repository.thumbnail(imageID: XCTUnwrap(first.imageID))
        XCTAssertNotNil(UIImage(data: bytes))
        _ = try await repository.setStatus(id: first.id, availability: .laundry, archived: true)
        let changed = try await repository.detail(id: first.id)
        XCTAssertTrue(changed.garment.archived)
        let reset = try await DemoWardrobe.make().detail(id: first.id)
        XCTAssertFalse(reset.garment.archived)
        XCTAssertEqual(reset.garment.availability, .available)
        let outfit = Outfit(name: "Przykład", garments: [first])
        let request = SaveOutfit(outfit)
        let saved = try await repository.saveOutfit(request)
        let replay = try await repository.saveOutfit(request)
        XCTAssertEqual(saved, replay)
    }
}
#endif

@MainActor
final class ArchitectureTests: XCTestCase {
    func testBuiltAppEnvironmentAndIdentityAgree() {
        let environment = Bundle.main.object(forInfoDictionaryKey: "AppEnvironment") as? String
        let expectedIDs = ["dev": "pl.mojaszafa.app.dev", "staging": "pl.mojaszafa.app.staging", "prod": "pl.mojaszafa.app"]
        XCTAssertNotNil(environment)
        XCTAssertNotNil(expectedIDs[environment ?? ""])
        XCTAssertEqual(Bundle.main.bundleIdentifier, expectedIDs[environment ?? ""])
        // Builds without an approved endpoint stay unavailable; a configured
        // build must compose the real HTTPS gateway rather than fixture data.
        let endpoint = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        if let endpoint, !endpoint.isEmpty {
            XCTAssertEqual(URL(string: endpoint)?.scheme, "https")
            XCTAssertTrue(AppDependencies.live().authentication is AuthenticationClient)
        }
    }

    func testLiveCompositionFailsExplicitlyInsteadOfReturningMockData() async {
        let model = WardrobeModel(repository: AppDependencies.live(backendBaseURL: nil, transport: GatewayFixture()).wardrobe)
        await model.load()
        XCTAssertEqual(model.state, .backendNotConfigured)
    }

    func testInjectedRepositoryReturnsNamesUnchanged() async {
        let garment = Garment(id: UUID(), name: "tab.today — Koszula")
        let model = WardrobeModel(repository: StubRepository(result: .success([garment])))
        await model.load()
        XCTAssertEqual(model.state, .loaded([garment]))
    }

    func testEmptyIsDifferentFromFailure() async {
        let empty = WardrobeModel(repository: StubRepository(result: .success([])))
        let failed = WardrobeModel(repository: StubRepository(result: .failure(URLError(.badServerResponse))))
        await empty.load()
        await failed.load()
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(failed.state, .failed)
    }

    func testOfflineCanRetrySuccessfully() async {
        let repository = RetryRepository()
        let model = WardrobeModel(repository: repository)
        await model.load()
        XCTAssertEqual(model.state, .offline)
        await model.load()
        XCTAssertEqual(model.state, .empty)
    }

    func testCancellationDoesNotBecomeAnError() async {
        let model = WardrobeModel(repository: StubRepository(result: .failure(CancellationError())))
        await model.load()
        XCTAssertEqual(model.state, .idle)
    }

    func testConcurrentLoadIsDeduplicatedAndCancelledResultIsDiscarded() async {
        let repository = SuspendedRepository()
        let model = WardrobeModel(repository: repository)
        let first = Task { await model.load() }
        await repository.waitUntilStarted()
        XCTAssertEqual(model.state, .loading)
        await model.load()
        let calls = await repository.calls
        XCTAssertEqual(calls, 1)
        first.cancel()
        await repository.finish()
        await first.value
        XCTAssertEqual(model.state, .idle)
    }

    func testMissingAndUnsafeGatewayConfigurationNeverSendsRequests() async {
        let transport = GatewayFixture()
        var credentialURL = URLComponents(string: "https://example.invalid")!
        credentialURL.user = "synthetic-user"
        credentialURL.password = "fixture"
        for endpoint in [nil, "", "  ", "$(BACKEND_BASE_URL)", "http://example.invalid",
                         credentialURL.string, "https://example.invalid?token=x",
                         "https://example.invalid#fragment", "not-a-url"] as [String?] {
            let dependencies = AppDependencies.live(backendBaseURL: endpoint, transport: transport)
            XCTAssertTrue(dependencies.authentication is UnconfiguredAuthenticationService)
            do { _ = try await dependencies.authentication.startEmail("person@example.invalid"); XCTFail("Must stay unconfigured") }
            catch { XCTAssertEqual(error as? AuthError, .notConfigured) }
            do { _ = try await dependencies.wardrobe.garments(); XCTFail("Must not provide fixture data") }
            catch { XCTAssertEqual(error as? RepositoryError, .backendNotConfigured) }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLiveGatewayEmailRefreshWardrobeAndLogoutContract() async throws {
        let transport = GatewayFixture()
        let dependencies = AppDependencies.live(backendBaseURL: "https://gateway.example.invalid", transport: transport)
        let credentials = GatewaySessionStore()
        let model = AuthenticationModel(service: dependencies.authentication, store: credentials)
        await model.startEmail("person@example.invalid")
        XCTAssertNotNil(model.challenge)
        await model.verifyEmail("123456")
        XCTAssertEqual(credentials.value?.accessToken, "opaque-provider-session.signature")
        XCTAssertEqual(credentials.value?.refreshToken, credentials.value?.accessToken)
        let directory = temporaryGatewayStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authenticated = dependencies.authenticated(using: model, storageDirectory: directory)
        XCTAssertNotNil(authenticated.offline)
        let garments = try await authenticated.wardrobe.garments()
        XCTAssertEqual(garments.map(\.name), ["Gateway shirt"])
        let requests = await transport.requests
        XCTAssertEqual(requests.prefix(3).compactMap { $0.url?.path },
                       ["/auth/v1/email/start", "/auth/v1/email/verify", "/auth/v1/refresh"])
        let resources = requests.filter { $0.url?.path == "/rest/v1/rpc/api_v1_sync_snapshot" }
        XCTAssertFalse(resources.isEmpty)
        XCTAssertTrue(resources.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-provider-session.signature" })
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "gateway.example.invalid" && $0.value(forHTTPHeaderField: "apikey") == nil })
        let refresh = try XCTUnwrap(requests.first { $0.url?.path == "/auth/v1/refresh" })
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(refresh.httpBody)),
                       ["refreshToken": "opaque-provider-session.signature"])
        await model.logout()
        XCTAssertNil(credentials.value)
        XCTAssertNil(model.session)
        let logout = await transport.requests.last
        XCTAssertEqual(logout?.url?.path, "/auth/v1/logout")
    }

    func testLogoutAndAccountSwitchDoNotExposePreviousWardrobeCache() async throws {
        let transport = GatewayFixture()
        let dependencies = AppDependencies.live(backendBaseURL: "https://gateway.example.invalid", transport: transport)
        let credentials = GatewaySessionStore()
        let model = AuthenticationModel(service: dependencies.authentication, store: credentials)
        let directory = temporaryGatewayStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        await model.startEmail("first@example.invalid")
        await model.verifyEmail("123456")
        let firstID = try XCTUnwrap(model.session?.userID)
        let first = try XCTUnwrap(dependencies.authenticated(using: model, storageDirectory: directory).offline)
        let firstGarments = try await first.garments()
        XCTAssertEqual(firstGarments.map(\.name), ["Gateway shirt"])
        let garmentID = try XCTUnwrap(firstGarments.first?.id)
        _ = try await first.recordWear(wornOn: "2026-11-01", timezone: "Europe/Warsaw", garmentIDs: [garmentID])
        let firstState = await first.status()
        XCTAssertEqual(firstState.wears.count, 1)
        XCTAssertFalse(firstState.outbox.isEmpty, "The first account must have durable pending work to isolate")

        await model.logout()
        XCTAssertNil(credentials.value)
        await transport.changeAccount()
        await transport.disconnectResources()
        await model.startEmail("second@example.invalid")
        await model.verifyEmail("123456")
        let secondID = try XCTUnwrap(model.session?.userID)
        XCTAssertNotEqual(firstID, secondID)
        let second = try XCTUnwrap(dependencies.authenticated(using: model, storageDirectory: directory).offline)
        // No network snapshot can hide accidental reuse of the first account's SQLite cache.
        let secondGarments = try await second.garments()
        XCTAssertTrue(secondGarments.isEmpty)
        let secondState = await second.status()
        XCTAssertEqual(secondState.accountID, secondID)
        XCTAssertTrue(secondState.wears.isEmpty)
        XCTAssertTrue(secondState.outbox.isEmpty)
        let reopened = try XCTUnwrap(dependencies.authenticated(using: model, storageDirectory: directory).offline)
        let reopenedGarments = try await reopened.garments()
        XCTAssertTrue(reopenedGarments.isEmpty, "Isolation must survive reopening the durable store")

        let before = await transport.requests.count
        do { try await first.synchronize(); XCTFail("Logged-out work must not borrow the second account's credentials") }
        catch { XCTAssertEqual(error as? AuthError, .expired) }
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
    }

    func testLiveGatewayRejectsResource401AndOldAccountWork() async throws {
        let transport = GatewayFixture()
        let dependencies = AppDependencies.live(backendBaseURL: "https://gateway.example.invalid", transport: transport)
        let credentials = GatewaySessionStore()
        let model = AuthenticationModel(service: dependencies.authentication, store: credentials)
        await model.startEmail("first@example.invalid")
        await model.verifyEmail("123456")
        let directory = temporaryGatewayStorage()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(dependencies.authenticated(using: model, storageDirectory: directory).offline)
        await transport.rejectResources()
        do { try await store.synchronize(); XCTFail("401 must fail") } catch {}
        XCTAssertNil(model.session)
        XCTAssertNil(credentials.value)
        await transport.changeAccount()
        await model.startEmail("second@example.invalid")
        await model.verifyEmail("123456")
        XCTAssertNotNil(model.session)
        let before = await transport.requests.count
        do { try await store.synchronize(); XCTFail("Old account work must not use the new session") }
        catch { XCTAssertEqual(error as? AuthError, .expired) }
        let after = await transport.requests.count
        XCTAssertEqual(before, after)
    }

    func testCredentialsAreScopedToGatewayAndTransportDoesNotPersistOrRedirect() async throws {
        let transport = URLSessionTransport.gateway()
        defer { transport.session.invalidateAndCancel() }
        let first = AppDependencies.live(backendBaseURL: "https://first.example.invalid", transport: transport)
        let second = AppDependencies.live(backendBaseURL: "https://second.example.invalid", transport: transport)
        let unavailable = AppDependencies.live(backendBaseURL: nil, transport: transport)
        XCTAssertNotEqual(first.sessionStoreService, second.sessionStoreService)
        XCTAssertNotEqual(first.sessionStoreService, unavailable.sessionStoreService)
        let configuration = transport.session.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        let policy = try XCTUnwrap(transport.session.delegate as? GatewayRedirectPolicy)
        let target = URL(string: "https://different.example.invalid")!
        let task = transport.session.dataTask(with: target) // Never resumed; no real request.
        let redirect = HTTPURLResponse(url: target, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let accepted: URLRequest? = await withCheckedContinuation { continuation in
            policy.urlSession(transport.session, task: task, willPerformHTTPRedirection: redirect,
                              newRequest: URLRequest(url: target)) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(accepted)
    }

    private func temporaryGatewayStorage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("gateway-tests-" + UUID().uuidString)
    }
}

@MainActor
private final class GatewaySessionStore: SessionStore {
    var value: AuthSession?
    func read() throws -> AuthSession? { value }
    func write(_ session: AuthSession) throws { value = session }
    func clear() throws { value = nil }
}

private actor GatewayFixture: APITransport {
    private(set) var requests: [URLRequest] = []
    private var userID = UUID()
    private let challenge = UUID()
    private let garmentID = UUID()
    private var unauthorized = false
    private var resourcesDisconnected = false
    func rejectResources() { unauthorized = true }
    func disconnectResources() { resourcesDisconnected = true }
    func changeAccount() { userID = UUID(); unauthorized = false }

    private struct Envelope<Value: Encodable>: Encodable {
        let data: Value
        let request_id = UUID()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data: Data
        var status = 200
        switch request.url!.path {
        case "/auth/v1/email/start":
            data = try encoder.encode(["challengeID": challenge.uuidString])
        case "/auth/v1/email/verify", "/auth/v1/refresh":
            data = try encoder.encode(AuthSession(userID: userID, accessToken: "opaque-provider-session.signature",
                refreshToken: "opaque-provider-session.signature", expiresAt: Date().addingTimeInterval(
                    request.url!.path.hasSuffix("refresh") ? 3600 : 30)))
        case "/auth/v1/logout": data = Data("{}".utf8)
        case "/rest/v1/rpc/api_v1_sync_snapshot":
            if resourcesDisconnected { throw URLError(.networkConnectionLost) }
            if unauthorized { status = 401; data = Data() }
            else {
                let garment = SyncGarment(id: garmentID, version: 1, deleted: false,
                    fields: APIv1.GarmentFields(name: "Gateway shirt", category: .top, priceGrosz: nil, availability: .available))
                data = try encoder.encode(Envelope(data: SyncSnapshot(accountID: userID, garments: [garment], wears: [])))
            }
        default: throw URLError(.unsupportedURL)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct StubRepository: WardrobeRepository {
    let result: Result<[Garment], any Error>
    func garments() async throws -> [Garment] { try result.get() }
}

private actor RetryRepository: WardrobeRepository {
    private var calls = 0
    func garments() async throws -> [Garment] {
        calls += 1
        if calls == 1 { throw URLError(.notConnectedToInternet) }
        return []
    }
}

/// Explicit suspension avoids sleeps and tests a provider that ignores cancellation.
private actor SuspendedRepository: WardrobeRepository {
    private(set) var calls = 0
    private var pending: CheckedContinuation<[Garment], Never>?
    private var started: CheckedContinuation<Void, Never>?

    func garments() async throws -> [Garment] {
        calls += 1
        return await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        pending?.resume(returning: [])
        pending = nil
    }
}
