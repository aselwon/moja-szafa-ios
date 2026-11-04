import XCTest
import UIKit
@testable import MojaSzafa

@MainActor
final class PurchasePreviewTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testConfirmationRetryAfterRecreationPreservesOperation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PurchaseFixture(); let id = UUID()
        let first = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await first.confirm(id)
        XCTAssertEqual(first.message, "outfits.offline")
        let second = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await second.confirm(id)
        let requests = await service.confirmations
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(second.message, "purchase.purchased")
    }
    func testUploadRetryPreservesCandidateAndOriginalDetailsAcrossRelaunch() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PurchaseFixture()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let first = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await first.create(name: "Original", price: nil, metadata: PurchaseMetadata(), photo: photo)
        XCTAssertNotNil(first.journal.draft)
        let next = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await next.create(name: "Changed", price: 999, metadata: PurchaseMetadata(category: .dress), photo: nil)
        let requests = await service.creates
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[0], requests[1]); XCTAssertEqual(requests[1].name, "Original")
        XCTAssertNil(next.journal.draft); XCTAssertEqual(next.items.count, 1)
        let confirmations = await service.confirmations
        XCTAssertTrue(confirmations.isEmpty)
    }
    func testWireIncludesNullPriceAndUnknownFormality() throws {
        let request = PurchaseCreate(operation_id: UUID(), candidate_id: UUID(), name: "Candidate", price_grosz: nil, metadata: PurchaseMetadata())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertTrue(json["price_grosz"] is NSNull)
        XCTAssertTrue((json["metadata"] as? [String: Any])?["formality"] is NSNull)
    }
    func testPendingJobResumeDoesNotReadmitOrConfirmPurchase() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PurchaseFixture(); let id = UUID()
        let model = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await model.check(id, maxPolls: 1)
        let restored = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await restored.check(id, maxPolls: 1)
        let admissions = await service.admissions; let confirmations = await service.confirmations
        XCTAssertEqual(admissions.count, 1); XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(restored.message, "purchase.pending")
    }
    func testUnreadableJournalFailsClosed() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("intents.json"))
        let service = PurchaseFixture()
        let model = PurchasePreviewModel(repository: service, wardrobe: PurchaseWardrobe(), directory: root)
        await model.confirm(UUID())
        let confirmations = await service.confirmations
        XCTAssertTrue(confirmations.isEmpty); XCTAssertEqual(model.message, "purchase.storage")
    }
}
private struct PurchaseWardrobe: WardrobeRepository {
    func garments() async throws -> [Garment] { [] }
}
private actor PurchaseFixture: PurchaseRepository {
    var confirmations: [UUID] = []
    var creates: [PurchaseCreate] = []
    var admissions: [UUID] = []
    var imageID: UUID?
    var failUpload = true
    let jobID = UUID()
    let garmentID = UUID()
    var completed = false
    var resultFails = false
    var checkedCandidateID: UUID?
    func completeResults() { completed = true }
    func failResults() { resultFails = true }
    func candidates() async throws -> [PurchaseCandidate] { [] }
    func createCandidate(_ request: PurchaseCreate) async throws -> PurchaseCandidate { creates.append(request); return try await candidate(request.candidate_id) }
    func candidate(_ id: UUID) async throws -> PurchaseCandidate {
        PurchaseCandidate(id: id, name: "Candidate", metadata: PurchaseMetadata(), price_grosz: nil, image_id: imageID,
            expires_at: Date().addingTimeInterval(3600).timeIntervalSince1970, status: "considering", garment_id: nil)
    }
    func uploadCandidatePhoto(candidateID: UUID, imageID: UUID, data: Data) async throws {
        self.imageID = imageID
        if failUpload { failUpload = false; throw URLError(.timedOut) }
    }
    func candidatePhoto(imageID: UUID) async throws -> Data { Data() }
    func confirmCandidate(id: UUID, operationID: UUID) async throws -> PurchaseCandidate {
        confirmations.append(operationID)
        if confirmations.count == 1 { throw URLError(.timedOut) }
        return PurchaseCandidate(id: id, name: "Owned", metadata: PurchaseMetadata(), price_grosz: nil, image_id: UUID(),
            expires_at: 0, status: "purchased", garment_id: UUID())
    }
    func discardCandidate(id: UUID, operationID: UUID) async throws {}
    func checkCandidate(id: UUID, operationID: UUID) async throws -> UUID { admissions.append(operationID); checkedCandidateID = id; return jobID }
    func candidateResult(jobID: UUID) async throws -> PurchaseJob {
        if resultFails { throw URLError(.notConnectedToInternet) }
        let result = completed ? PurchaseFit(outfits: [.init(garment_ids: [garmentID], rationale: "Compatible", complete: false, missing_categories: [], purchase_candidate_id: checkedCandidateID!)], shortfall_reason: "One match") : nil
        return PurchaseJob(job_id: jobID, kind: .purchaseFit, status: completed ? .succeeded : .queued, result: result, error_code: nil)
    }
}


extension PurchasePreviewTests {
    func testSuccessfulAdviceClearsBeforeStaleWardrobeRecheck() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PurchaseFixture(); await service.completeResults()
        let wardrobe = MutablePurchaseWardrobe(items: [Garment(id: service.garmentID, name: "Owned")])
        let model = PurchasePreviewModel(repository: service, wardrobe: wardrobe, directory: root)
        let id = UUID(); await model.check(id, maxPolls: 1)
        XCTAssertEqual(model.matches[id]?.count, 1)
        await wardrobe.removeAll()
        await model.check(id, maxPolls: 1)
        XCTAssertNil(model.matches[id]); XCTAssertEqual(model.message, "purchase.stale")
    }
    func testSuccessfulAdviceClearsOnFailedRecheckAndListRemoval() async {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = PurchaseFixture(); await service.completeResults()
        let wardrobe = MutablePurchaseWardrobe(items: [Garment(id: service.garmentID, name: "Owned")])
        let model = PurchasePreviewModel(repository: service, wardrobe: wardrobe, directory: root)
        let first = UUID(); await model.check(first, maxPolls: 1)
        XCTAssertEqual(model.matches[first]?.count, 1)
        await model.load()
        XCTAssertNil(model.matches[first])
        let second = UUID(); await model.check(second, maxPolls: 1)
        XCTAssertEqual(model.matches[second]?.count, 1)
        await service.failResults()
        await model.check(second, maxPolls: 1)
        XCTAssertNil(model.matches[second]); XCTAssertEqual(model.message, "outfits.offline")
    }
    func testFailedPhotoSelectionCannotSubmitPreviousPhoto() async {
        let photos = PurchasePhotoSelection()
        await photos.select(load: { Data([1]) }, normalize: { $0 })
        XCTAssertEqual(photos.data, Data([1]))
        await photos.select(load: { throw PhotoImportError.invalidImage }, normalize: { $0 })
        XCTAssertNil(photos.data); XCTAssertTrue(photos.failed)
    }
    func testCancelledOlderPhotoSelectionCannotClearNewerPhoto() async {
        let photos = PurchasePhotoSelection(); let gate = PurchasePhotoGate()
        let older = Task { await photos.select(load: { try await gate.wait() }, normalize: { $0 }) }
        while !(await gate.ready) { await Task.yield() }
        XCTAssertNil(photos.data)
        await photos.select(load: { Data([2]) }, normalize: { $0 })
        older.cancel(); await gate.fail(); await older.value
        XCTAssertEqual(photos.data, Data([2])); XCTAssertFalse(photos.failed)
    }
}
private actor MutablePurchaseWardrobe: WardrobeRepository {
    var items: [Garment]
    init(items: [Garment]) { self.items = items }
    func garments() async throws -> [Garment] { items }
    func removeAll() { items = [] }
}
private actor PurchasePhotoGate {
    var continuation: CheckedContinuation<Data?, any Error>?
    var ready: Bool { continuation != nil }
    func wait() async throws -> Data? { try await withCheckedThrowingContinuation { continuation = $0 } }
    func fail() { continuation?.resume(throwing: PhotoImportError.invalidImage); continuation = nil }
}
