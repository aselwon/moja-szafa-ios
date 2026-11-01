import XCTest
@testable import MojaSzafa

@MainActor
final class ArchitectureTests: XCTestCase {
    func testBuiltAppEnvironmentAndIdentityAgree() {
        let environment = Bundle.main.object(forInfoDictionaryKey: "AppEnvironment") as? String
        let expectedIDs = ["dev": "pl.mojaszafa.app.dev", "staging": "pl.mojaszafa.app.staging", "prod": "pl.mojaszafa.app"]
        XCTAssertNotNil(environment)
        XCTAssertNotNil(expectedIDs[environment ?? ""])
        XCTAssertEqual(Bundle.main.bundleIdentifier, expectedIDs[environment ?? ""])
        // Until T007/T009 approve endpoints, every environment must remain offline.
        let endpoint = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
        XCTAssertTrue(endpoint == nil || endpoint == "")
    }

    func testLiveCompositionFailsExplicitlyInsteadOfReturningMockData() async {
        let model = WardrobeModel(repository: AppDependencies.live().wardrobe)
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
