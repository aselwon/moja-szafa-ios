import XCTest
import CryptoKit
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

private actor LostDeletionReceiptStub: AccountDeletionService {
    var requests = 0
    func challenge() async throws -> DeletionChallenge { .init(id: UUID(), method: "email", nonce: nil, state: nil) }
    func delete(operationID: UUID, proof: [String: String]) async throws { requests += 1; throw URLError(.timedOut) }
    func receipt(operationID: UUID, challengeID: UUID, token: String?) async throws -> Bool { requests > 0 }
}

private struct DeletionReceiptTransport: APITransport {
    let operationID: UUID
    let challengeID: UUID
    let token: String
    var accepted = true
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.path, "/v1/account/deletion/status")
        XCTAssertNil(request.url?.query)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body["operation_id"]?.lowercased(), operationID.uuidString.lowercased())
        XCTAssertEqual(body["challenge_id"]?.lowercased(), challengeID.uuidString.lowercased())
        XCTAssertEqual(body["receipt_token"], token)
        return (try JSONSerialization.data(withJSONObject: ["accepted": accepted]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class DeletionSessionStore: SessionStore {
    func read() throws -> AuthSession? { nil }
    func write(_ session: AuthSession) throws { throw AuthError.storage }
    func clear() throws {}
}

@MainActor
final class AccountDeletionTests: XCTestCase {
    func testLoggedOutStartupRecoveryClearsOnlyConfirmedAccountAndRetainsCorruptJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = UUID(), other = UUID(), challenge = UUID(), token = String(repeating: "A", count: 43)
        let base = URL(string: "https://example.test")!
        let namespace = SHA256.hash(data: Data(base.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent("DeletionProgress").appendingPathComponent(namespace)
        let journal = directory.appendingPathComponent(account.uuidString + ".json")
        try DeletionProgress(operationID: account, challenge: .init(id: challenge, method: "email", nonce: nil, state: nil, receiptToken: token), accepted: false).write(to: journal)
        let corrupt = directory.appendingPathComponent(other.uuidString + ".json")
        try Data("broken".utf8).write(to: corrupt)
        let wardrobe = root.appendingPathComponent("Wardrobe").appendingPathComponent(namespace)
        let database = OfflineDatabase(url: wardrobe.appendingPathComponent(account.uuidString + ".sqlite"))
        try database.write(JSONEncoder().encode(OfflineStore.State(accountID: account)))
        let photos = database.url.appendingPathExtension("images")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: photos.appendingPathComponent("photo.image"))
        let otherFile = wardrobe.appendingPathComponent(other.uuidString + ".sqlite")
        try Data("other-account".utf8).write(to: otherFile)
        let dependencies = try AppDependencies.configured(baseURL: base, authentication: UnconfiguredAuthenticationService(),
            transport: DeletionReceiptTransport(operationID: account, challengeID: challenge, token: token))
        let model = AuthenticationModel(service: UnconfiguredAuthenticationService(), store: DeletionSessionStore())
        let pendingDependencies = try AppDependencies.configured(baseURL: base, authentication: UnconfiguredAuthenticationService(),
            transport: DeletionReceiptTransport(operationID: account, challengeID: challenge, token: token, accepted: false))
        await pendingDependencies.recoverDeletions(using: model, active: nil, activeAccountID: nil, storageDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "An unaccepted request must retain recovery state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photos.path), "Unknown acceptance must not erase local data")
        await dependencies.recoverDeletions(using: model, active: nil, activeAccountID: nil, storageDirectory: root)
        XCTAssertNil(model.session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: photos.path))
        let state = try JSONDecoder().decode(OfflineStore.State.self, from: XCTUnwrap(database.read()))
        XCTAssertTrue(state.deleted); XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertEqual(try Data(contentsOf: otherFile), Data("other-account".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }

    func testReceiptCapabilityRecoversAfterLoginSessionIsGone() async throws {
        let operation = UUID(), challenge = UUID(), token = String(repeating: "A", count: 43)
        let client = AccountDeletionClient(baseURL: URL(string: "https://example.test")!,
            transport: DeletionReceiptTransport(operationID: operation, challengeID: challenge, token: token),
            accessToken: { throw AuthError.expired })
        let accepted = try await client.receipt(operationID: operation, challengeID: challenge, token: token)
        XCTAssertTrue(accepted)
    }

    func testLostAcceptedResponseResumesFromDurableChallengeWithoutAnotherOTPOrDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("deletion.json"), id = UUID()
        let service = LostDeletionReceiptStub()
        var cleanups = 0
        let first = AccountDeletionModel(service: service, operationID: id, journalURL: journal) { cleanups += 1 }
        await first.begin(); let challenge = first.challenge?.id
        await first.submit(["code": "123456"])
        XCTAssertFalse(first.accepted); XCTAssertEqual(cleanups, 0)
        let stored = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertFalse(stored.contains("123456"), "OTP must never be persisted")
        let restarted = AccountDeletionModel(service: service, operationID: id, journalURL: journal) { cleanups += 1 }
        XCTAssertEqual(restarted.challenge?.id, challenge)
        await restarted.resume()
        XCTAssertTrue(restarted.accepted); XCTAssertEqual(cleanups, 1)
        let requests = await service.requests; XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testAcceptedReceiptSurvivesCleanupFailureAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("deletion.json"), id = UUID()
        try DeletionProgress(operationID: id, challenge: nil, accepted: true).write(to: journal)
        let service = DeletionStub()
        let first = AccountDeletionModel(service: service, operationID: id, journalURL: journal) { throw AuthError.storage }
        await first.resume()
        XCTAssertEqual(first.message, "deletion.cleanupError")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        var cleaned = false
        let restarted = AccountDeletionModel(service: service, operationID: id, journalURL: journal) { cleaned = true }
        await restarted.resume()
        XCTAssertTrue(cleaned); XCTAssertEqual(restarted.message, "deletion.accepted")
        let requests = await service.ids(); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    func testCorruptOrForeignProgressCannotStartAnotherDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("deletion.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for data in [Data("broken".utf8), try JSONEncoder().encode(DeletionProgress(operationID: UUID(), challenge: nil, accepted: true))] {
            try data.write(to: journal)
            let service = DeletionStub()
            var cleaned = false
            let model = AccountDeletionModel(service: service, operationID: UUID(), journalURL: journal) { cleaned = true }
            await model.begin(); await model.submit(["code": "123456"]); await model.resume()
            XCTAssertFalse(cleaned); XCTAssertFalse(model.accepted)
            let requests = await service.ids(); XCTAssertTrue(requests.isEmpty)
        }
    }


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
