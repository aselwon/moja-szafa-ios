import XCTest
@testable import MojaSzafa

private actor DeletionStub: AccountDeletionService {
    var operations: [UUID] = []
    func challenge() async throws -> DeletionChallenge {
        DeletionChallenge(id: UUID(), method: "email", nonce: nil, state: nil)
    }
    func delete(operationID: UUID, proof: [String: String]) async throws {
        operations.append(operationID)
        guard proof["challenge_id"] != nil else { throw AuthError.rejected }
        if operations.count == 1 { throw URLError(.timedOut) }
    }
    func ids() -> [UUID] { operations }
}

@MainActor
final class AccountDeletionTests: XCTestCase {
    func testTimeoutRetryAndLocalCleanupFailureDoNotCreateAnotherDeletion() async {
        let service = DeletionStub()
        var cleanups = 0
        let id = UUID()
        let model = AccountDeletionModel(service: service, operationID: id) {
            cleanups += 1
            if cleanups == 1 { throw AuthError.storage }
        }
        await model.begin()
        await model.submit(["code": "123456"])
        XCTAssertFalse(model.accepted)
        XCTAssertEqual(cleanups, 0)
        await model.submit(["code": "123456"])
        XCTAssertTrue(model.accepted)
        XCTAssertEqual(model.message, "deletion.cleanupError")
        await model.submit([:])
        XCTAssertEqual(model.message, "deletion.accepted")
        let ids = await service.ids()
        XCTAssertEqual(ids, [id, id])
        XCTAssertEqual(cleanups, 2)
    }
    func testUnconfiguredServiceDoesNotReportDeletion() async {
        var cleaned = false
        let model = AccountDeletionModel(service: nil, operationID: UUID()) { cleaned = true }
        await model.begin()
        await model.submit([:])
        XCTAssertFalse(model.accepted)
        XCTAssertFalse(cleaned)
        XCTAssertEqual(model.message, "deletion.unconfigured")
    }
}
