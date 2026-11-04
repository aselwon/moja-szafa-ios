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
    func checkCandidate(id: UUID, operationID: UUID) async throws -> UUID { admissions.append(operationID); return jobID }
    func candidateResult(jobID: UUID) async throws -> PurchaseJob {
        PurchaseJob(job_id: jobID, kind: .purchaseFit, status: .queued, result: nil, error_code: nil)
    }
}
