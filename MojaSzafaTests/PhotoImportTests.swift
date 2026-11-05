import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import MojaSzafa

@MainActor
final class PhotoImportTests: XCTestCase {
    func testOfflineImportsEditAndWearSurviveRestartAndUploadTimeoutWithoutDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = root.appendingPathComponent("drafts")
        let accountID = UUID()
        let remote = ImportedGarmentRemote(accountID: accountID)
        let database = OfflineDatabase(url: root.appendingPathComponent("wardrobe.sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: remote)
        let model = PhotoImportModel(directory: drafts)
        let photo = try fixture()
        model.start([{ photo }, { photo }])
        await finish(model)
        let ids = model.drafts.map(\.id)
        XCTAssertEqual(ids.count, 2)
        let value = GarmentFormValue(name: "Same shirt", category: .top, colors: ["blue"], pattern: "plain",
            seasons: ["summer"], formality: 2, brand: "Example", priceGrosz: 4500, purchasedOn: "2026-01-01")
        for id in ids { try await model.commitGarmentValue(value, for: id, repository: store) }
        XCTAssertTrue(model.drafts.isEmpty, "The durable outbox owns both photos while offline")
        try await store.saveGarment(id: ids[0], fields: .init(name: "Edited offline", category: .top, priceGrosz: 4500, availability: .laundry))
        try await store.recordWear(wornOn: "2026-01-01", timezone: "Europe/Warsaw", garmentIDs: [ids[0]])
        let reopenedStore = try OfflineStore(accountID: accountID, database: database, remote: remote)
        let offlinePage = try await reopenedStore.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertEqual(Set(offlinePage.items.map(\.id)), Set(ids))
        XCTAssertTrue(offlinePage.cached)
        XCTAssertEqual(offlinePage.items.first(where: { $0.id == ids[0] })?.name, "Edited offline")
        for garment in offlinePage.items {
            let bytes = try await reopenedStore.thumbnail(imageID: XCTUnwrap(garment.imageID))
            XCTAssertFalse(bytes.isEmpty, "New photos remain visible without the network")
            XCTAssertEqual(garment.brand, "Example")
        }
        var counts = await remote.counts()
        XCTAssertEqual(counts.operations, 0)
        await remote.goOnline()
        do { try await reopenedStore.synchronize(); XCTFail("Upload commits then times out") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let retried = try OfflineStore(accountID: accountID, database: database, remote: remote)
        try await retried.synchronize(now: Date().addingTimeInterval(60))
        try await retried.synchronize(now: Date().addingTimeInterval(120))
        let status = await retried.status()
        XCTAssertTrue(status.outbox.isEmpty)
        XCTAssertEqual(status.garments.count, 2)
        counts = await remote.counts()
        XCTAssertEqual(counts.operations, 2)
        XCTAssertEqual(counts.images, 2)
        XCTAssertEqual(counts.wears, 1)
        let secondDevice = try OfflineStore(accountID: accountID,
            database: OfflineDatabase(url: root.appendingPathComponent("second.sqlite")), remote: remote)
        let secondPage = try await secondDevice.page(query: WardrobeQuery(), offset: 0, limit: 40)
        XCTAssertEqual(Set(secondPage.items.map(\.id)), Set(ids))
        XCTAssertEqual(Set(secondPage.items.compactMap(\.imageID)).count, 2)
        XCTAssertEqual(secondPage.items.first(where: { $0.id == ids[0] })?.name, "Edited offline")
        XCTAssertEqual(secondPage.items.first(where: { $0.id == ids[0] })?.colors, ["blue"])
    }

    func testAccountDeletionRemovesQueuedImportAndPrivatePhotoBeforeReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = UUID(), imageID = UUID()
        let remote = ImportedGarmentRemote(accountID: accountID)
        let db = OfflineDatabase(url: root.appendingPathComponent("wardrobe.sqlite"))
        let store = try OfflineStore(accountID: accountID, database: db, remote: remote)
        let operation = APIv1.SaveGarment(operationID: imageID, garmentID: UUID(), baseVersion: nil,
            garment: .init(name: "Private shirt", category: .top, priceGrosz: nil, availability: .available))
        try await store.importGarment(operation, image: fixture())
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.url.appendingPathExtension("images").path))
        try await store.invalidateAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.url.appendingPathExtension("images").path))
        await remote.goOnline()
        let reopened = try OfflineStore(accountID: accountID, database: db, remote: remote)
        do { try await reopened.synchronize(); XCTFail("Deleted account cannot upload") }
        catch { XCTAssertEqual(error as? OfflineError, .accountDeleted) }
        do { _ = try await reopened.thumbnail(imageID: imageID); XCTFail("Deleted photo cannot be read") }
        catch { XCTAssertEqual(error as? OfflineError, .accountDeleted) }
        let counts = await remote.counts()
        XCTAssertEqual(counts.operations, 0)
        XCTAssertEqual(counts.images, 0)
    }

    func testAccountDeletionDuringPhotoUploadCannotRestoreLocalData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = UUID(), photoID = UUID()
        let remote = ImportedGarmentRemote(accountID: accountID)
        await remote.suspendNextUpload()
        let db = OfflineDatabase(url: root.appendingPathComponent("wardrobe.sqlite"))
        let store = try OfflineStore(accountID: accountID, database: db, remote: remote)
        let operation = APIv1.SaveGarment(operationID: photoID, garmentID: UUID(), baseVersion: nil,
            garment: .init(name: "Private shirt", category: .top, priceGrosz: nil, availability: .available))
        try await store.importGarment(operation, image: fixture())
        let sync = Task { try await store.synchronize() }
        await remote.waitForUpload()
        try await store.invalidateAccount()
        await remote.releaseUpload()
        do { try await sync.value; XCTFail("Late upload must not restore a deleted account") }
        catch { XCTAssertEqual(error as? OfflineError, .accountDeleted) }
        let state = await store.status()
        XCTAssertTrue(state.deleted)
        XCTAssertTrue(state.garments.isEmpty)
        XCTAssertTrue(state.outbox.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.url.appendingPathExtension("images").path))
    }

    func testEditedImportRetainsSourceAndTransparentEditAcrossRestartAndReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountID = UUID()
        let pairedRemote = ImportedGarmentRemote(accountID: accountID)
        let database = OfflineDatabase(url: root.appendingPathComponent("wardrobe.sqlite"))
        let store = try OfflineStore(accountID: accountID, database: database, remote: pairedRemote)
        let model = PhotoImportModel(directory: root.appendingPathComponent("drafts"))
        let input = try fixture()
        model.start([{ input }]); await finish(model)
        let draft = try XCTUnwrap(model.drafts.first)
        let original = try Data(contentsOf: XCTUnwrap(draft.file))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let edited = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { ctx in
            UIColor.green.setFill(); ctx.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        }.pngData())
        XCTAssertTrue(model.acceptEdit(edited, for: draft.id))
        let value = GarmentFormValue(name: "Edited shirt", category: .top, colors: [], pattern: "plain",
            seasons: [], formality: 2, brand: nil, priceGrosz: nil, purchasedOn: nil)
        try await model.commitGarmentValue(value, for: draft.id, repository: store)
        XCTAssertTrue(model.drafts.isEmpty)
        let restarted = try OfflineStore(accountID: accountID, database: database, remote: pairedRemote)
        let detail = try await restarted.detail(id: draft.id)
        XCTAssertEqual(detail.garment.hasCleanedImage, true)
        let imageID = try XCTUnwrap(detail.garment.imageID)
        let storedOriginal = try await restarted.original(imageID: imageID)
        let storedEdit = try await restarted.cleaned(imageID: imageID)
        XCTAssertEqual(storedOriginal, original); XCTAssertEqual(storedEdit, edited)
        await pairedRemote.goOnline()
        do { try await restarted.synchronize(); XCTFail("Expected committed upload timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await restarted.synchronize(now: Date().addingTimeInterval(60))
        let second = try OfflineStore(accountID: accountID, database: OfflineDatabase(url: root.appendingPathComponent("second.sqlite")), remote: pairedRemote)
        try await second.synchronize()
        let secondDetail = try await second.detail(id: draft.id)
        XCTAssertEqual(secondDetail.garment.hasCleanedImage, true)
        let secondOriginal = try await second.original(imageID: imageID)
        let secondEdit = try await second.cleaned(imageID: imageID)
        XCTAssertEqual(secondOriginal, original); XCTAssertEqual(secondEdit, edited)
        try await restarted.invalidateAccount()
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.url.appendingPathExtension("images").path))
    }

    private func fixture(type: UTType = .jpeg, orientation: Int = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1200))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 1200, y: 0, width: 1200, height: 1200))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testCompletedDraftDoesNotReappearAfterInterruptedCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try fixture().write(to: directory.appendingPathComponent(id + ".jpg"))
        try Data().write(to: directory.appendingPathComponent(id + ".completed"))
        XCTAssertTrue(PhotoImportModel(directory: directory).drafts.isEmpty)
    }

    func testJPEGAllOrientationsResizeAndRemoveGPS() async throws {
        let processor = PhotoProcessor()
        for orientation in 1...8 {
            let output = try await processor.normalize(fixture(orientation: orientation))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, orientation >= 5 ? 800 : 1600)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, orientation >= 5 ? 1600 : 800)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
            XCTAssertLessThan(output.count, PhotoProcessor.maxBytes)
        }
    }

    func testHEICConvertsToJPEG() async throws {
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        guard types.contains(UTType.heic.identifier) else {
            throw XCTSkip("HEIC encoder unavailable on this simulator; run on a physical iPhone")
        }
        let output = try await PhotoProcessor().normalize(fixture(type: .heic, orientation: 6))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testUnsupportedFormatFailsWithoutDraftFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        model.start([])
        XCTAssertTrue(model.drafts.isEmpty)
        let png = try fixture(type: .png)
        model.start([{ png }])
        await finish(model)
        XCTAssertEqual(model.drafts.map(\.status), ["import.failed"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testStorageFailureDoesNotReportSuccess() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let model = PhotoImportModel(directory: file)
        XCTAssertEqual(model.message, "import.storageFailed")
        let valid = try fixture()
        model.start([{ valid }])
        await finish(model)
        XCTAssertEqual(model.drafts.map(\.status), ["import.failed"])
        XCTAssertNil(model.drafts.first?.file)
    }

    func testBoundedFileRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0, count: PhotoProcessor.maxBytes).write(to: file)
        XCTAssertEqual(try PhotoProcessor.read(file).count, PhotoProcessor.maxBytes)
        try Data(repeating: 0, count: PhotoProcessor.maxBytes + 1).write(to: file)
        XCTAssertThrowsError(try PhotoProcessor.read(file))
    }

    func testMixedBatchRetainsSuccessAcrossFailureCancellationAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let valid = try fixture()
        model.start([
            { valid },
            { Data([0, 1, 2]) },
            { Data(repeating: 0, count: PhotoProcessor.maxBytes + 1) },
            { throw CancellationError() },
            { valid }
        ])
        await finish(model)
        XCTAssertEqual(model.drafts.map(\.status), ["import.ready", "import.failed", "import.tooLarge", "import.cancelled", "import.ready"])
        let reopened = PhotoImportModel(directory: directory)
        XCTAssertEqual(Set(reopened.drafts.map(\.id)), Set(model.drafts.filter { $0.file != nil }.map(\.id)))
        let first = try XCTUnwrap(reopened.drafts.first)
        reopened.remove(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first.file).path))
        XCTAssertEqual(PhotoImportModel(directory: directory).drafts.count, 1)
    }

    func testCancelKeepsCompletedDraftAndCancelsRemainingItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let valid = try fixture()
        model.start([{ valid }, { model.cancel(); return valid }, { valid }])
        await finish(model)
        XCTAssertEqual(model.drafts.map(\.status), ["import.ready", "import.cancelled", "import.cancelled"])
        XCTAssertEqual(PhotoImportModel(directory: directory).drafts.count, 1)
    }

    func testCropDimensionsAndInvalidBounds() async throws {
        let original = try await PhotoProcessor().normalize(fixture())
        let processor = PhotoEditorProcessor()
        let crop = PhotoCrop(width: 0.5, height: 0.5, horizontal: 1, vertical: 1)
        let output = try await processor.crop(original, to: crop)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 400)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        // The right half of the fixture is blue: verify crop position, not only dimensions.
        let pixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixel.deallocate() }
        let context = try XCTUnwrap(CGContext(data: pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[2], 200)
        XCTAssertLessThan(pixel[0], 30)
        XCTAssertThrowsError(try PhotoCrop(width: 0).rect(width: 100, height: 100))
        XCTAssertThrowsError(try PhotoCrop(horizontal: .nan).rect(width: 100, height: 100))
    }

    func testSegmentationFailureKeepsCroppedFallbackAndCropChangeInvalidatesPreview() async throws {
        let original = try await PhotoProcessor().normalize(fixture())
        let editor = PhotoEditorModel(original: original, segment: { _ in
            throw PhotoImportError.invalidImage
        })
        editor.crop.width = 0.5
        await editor.render(removeBackground: true)
        XCTAssertEqual(editor.message, "edit.segmentationFailed")
        let expected = try await PhotoEditorProcessor().crop(original, to: editor.crop)
        XCTAssertEqual(editor.preview, expected)
        XCTAssertFalse(editor.running)
        editor.crop.horizontal = 0
        XCTAssertNil(editor.preview)
        await editor.render(removeBackground: false)
        XCTAssertNotNil(editor.preview)
        XCTAssertNil(editor.message)
    }

    func testAcceptReopenReplaceAndRemovePreserveOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let input = try fixture()
        model.start([{ input }])
        await finish(model)
        let draft = try XCTUnwrap(model.drafts.first)
        let originalURL = try XCTUnwrap(draft.file)
        let original = try Data(contentsOf: originalURL)
        let editor = PhotoEditorModel(original: original, segment: { data in data })
        await editor.render(removeBackground: true)
        XCTAssertNil(editor.message)
        XCTAssertTrue(model.acceptEdit(try XCTUnwrap(editor.preview), for: draft.id))
        editor.crop.width = 0.5
        await editor.render(removeBackground: false)
        let selected = try XCTUnwrap(editor.preview)
        XCTAssertTrue(model.acceptEdit(selected, for: draft.id))
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        let reopened = PhotoImportModel(directory: directory)
        let restored = try XCTUnwrap(reopened.drafts.first)
        XCTAssertEqual(reopened.drafts.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.displayFile)), selected)
        reopened.remove(draft.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testAcceptedTransparentResultAndFailedReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let input = try fixture()
        model.start([{ input }])
        await finish(model)
        let draft = try XCTUnwrap(model.drafts.first)
        let originalURL = try XCTUnwrap(draft.file)
        let original = try Data(contentsOf: originalURL)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let transparent = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format)
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
            }.pngData())
        let editor = PhotoEditorModel(original: original, segment: { _ in transparent })
        await editor.render(removeBackground: true)
        XCTAssertEqual(editor.preview, transparent)
        XCTAssertTrue(model.acceptEdit(try XCTUnwrap(editor.preview), for: draft.id))
        let selectedURL = try XCTUnwrap(model.drafts.first?.displayFile)
        XCTAssertEqual(try Data(contentsOf: selectedURL), transparent)
        // An obstructed destination simulates a filesystem failure without permission assumptions.
        try FileManager.default.removeItem(at: selectedURL)
        try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: false)
        XCTAssertFalse(model.acceptEdit(transparent, for: draft.id))
        XCTAssertEqual(model.message, "import.storageFailed")
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
    }

    func testCancelledEditorDoesNotPublishResult() async throws {
        let original = try await PhotoProcessor().normalize(fixture())
        let editor = PhotoEditorModel(original: original)
        let task = Task { await editor.render(removeBackground: false) }
        task.cancel()
        await task.value
        XCTAssertNil(editor.preview)
        XCTAssertFalse(editor.running)
    }

    func testDuplicateFingerprintMatchesReencodingButRejectsDifferentColors() async throws {
        let detector = DuplicatePhotoDetector()
        let jpeg = try fixture()
        let png = try fixture(type: .png)
        let first = try await detector.fingerprint(jpeg)
        let identical = try await detector.fingerprint(jpeg)
        let reencoded = try await detector.fingerprint(png)
        XCTAssertTrue(first.resembles(identical))
        XCTAssertTrue(first.resembles(reencoded))
        XCTAssertNotEqual(first.digest, reencoded.digest)
        let other = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let different = try await detector.fingerprint(XCTUnwrap(other.jpegData(compressionQuality: 0.9)))
        XCTAssertFalse(first.resembles(different))
        do {
            _ = try await detector.fingerprint(Data([0, 1]))
            XCTFail("Invalid images must not produce a fingerprint")
        } catch {}
    }

    func testDuplicateWarningDoesNotMergeOrPreventSavingTwoCopies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let data = try fixture()
        model.start([{ data }, { data }])
        await finish(model)
        let first = model.drafts[0].id
        let second = model.drafts[1].id
        let review = await model.duplicateReview(for: second, repository: nil)
        XCTAssertEqual(review.matches.map(\.id), [first])
        XCTAssertTrue(review.incomplete)
        var input = GarmentFormInput()
        input.name = "Two identical shirts"
        let value = try input.validated()
        try model.saveGarmentValue(value, for: first)
        try model.saveGarmentValue(value, for: second)
        let reopened = PhotoImportModel(directory: directory)
        XCTAssertEqual(Set(reopened.drafts.map(\.id)), [first, second])
        XCTAssertEqual(try reopened.garmentValue(for: first), value)
        XCTAssertEqual(try reopened.garmentValue(for: second), value)
        let restoredReview = await reopened.duplicateReview(for: second, repository: nil)
        XCTAssertEqual(restoredReview.matches.map(\.id), [first])
        reopened.remove(first)
        let afterRemoval = await reopened.duplicateReview(for: second, repository: nil)
        XCTAssertTrue(afterRemoval.matches.isEmpty)
        XCTAssertEqual(try reopened.garmentValue(for: second), value)
    }

    func testDuplicateReviewIncludesWardrobeAndArchivedItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PhotoImportModel(directory: directory)
        let data = try fixture()
        model.start([{ data }])
        await finish(model)
        let active = Garment(id: UUID(), name: "Active", imageID: UUID())
        let archived = Garment(id: UUID(), name: "Archived", imageID: UUID(), archived: true)
        let another = Garment(id: UUID(), name: "Second page", imageID: UUID())
        let repository = DuplicateRepository(items: [active, another, archived], data: data)
        let review = await model.duplicateReview(for: model.drafts[0].id, repository: repository)
        XCTAssertFalse(review.incomplete)
        XCTAssertEqual(Set(review.matches.map(\.id)), [active.id, another.id, archived.id])
        let failed = await model.duplicateReview(for: model.drafts[0].id,
            repository: DuplicateRepository(items: [active], data: Data()))
        XCTAssertTrue(failed.incomplete)
        XCTAssertTrue(failed.matches.isEmpty)
    }

    private func finish(_ model: PhotoImportModel) async {
        let deadline = Date().addingTimeInterval(10)
        while model.running && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.running, "Import did not finish")
    }
}

private struct DuplicateRepository: WardrobeRepository {
    let items: [Garment]
    let data: Data
    func garments() async throws -> [Garment] { items }
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        // Force pagination to verify matches beyond the first page.
        query.page(items, offset: offset, limit: 1, cached: false)
    }
    func thumbnail(imageID: UUID) async throws -> Data { data }
}

private actor ImportedGarmentRemote: OfflineRemote {
    let accountID: UUID
    var operations: [UUID: APIv1.SaveGarment] = [:]
    var images: [UUID: Data] = [:]
    var cleanedImages: [UUID: Data] = [:]
    var failFirstUpload = true
    var online = false
    var wears: [UUID: SyncWear] = [:]
    func goOnline() { online = true }
    var holdUpload = false
    var heldUpload: CheckedContinuation<Void, Never>?
    var uploadObserver: CheckedContinuation<Void, Never>?
    func suspendNextUpload() { online = true; holdUpload = true; failFirstUpload = false }
    func waitForUpload() async {
        if heldUpload != nil { return }
        await withCheckedContinuation { uploadObserver = $0 }
    }
    func releaseUpload() { heldUpload?.resume(); heldUpload = nil; holdUpload = false }
    init(accountID: UUID) { self.accountID = accountID }
    func counts() -> (operations: Int, images: Int, wears: Int) { (operations.count, images.count, wears.count) }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO {
        guard online else { throw URLError(.notConnectedToInternet) }
        if let old = operations[operation.operationID] {
            XCTAssertEqual(old.garmentID, operation.garmentID)
            XCTAssertEqual(old.garment, operation.garment)
        }
        operations[operation.operationID] = operation
        return .init(id: operation.garmentID, version: 1, name: operation.garment.name,
            category: operation.garment.category, priceGrosz: operation.garment.priceGrosz, availability: .available)
    }
    func uploadGarmentPhotos(garmentID: UUID, imageID: UUID, photos: GarmentPhotos) async throws {
        if let old = cleanedImages[imageID] { XCTAssertEqual(old, photos.cleaned) }
        cleanedImages[imageID] = photos.cleaned
        try await uploadGarmentPhoto(garmentID: garmentID, imageID: imageID, data: photos.original)
    }
    func cleanedImage(id: UUID) async throws -> Data {
        guard online else { throw URLError(.notConnectedToInternet) }
        return try XCTUnwrap(cleanedImages[id])
    }
    func uploadGarmentPhoto(garmentID: UUID, imageID: UUID, data: Data) async throws {
        XCTAssertEqual(operations[imageID]?.garmentID, garmentID)
        if let old = images[imageID] { XCTAssertEqual(old, data) }
        images[imageID] = data
        if holdUpload {
            await withCheckedContinuation { continuation in
                heldUpload = continuation
                uploadObserver?.resume(); uploadObserver = nil
            }
        }
        if failFirstUpload { failFirstUpload = false; throw URLError(.timedOut) }
    }
    func snapshot() async throws -> SyncSnapshot {
        guard online else { throw URLError(.notConnectedToInternet) }
        return SyncSnapshot(accountID: accountID, garments: operations.values.map { operation in
            let fields = operation.garment
            return SyncGarment(id: operation.garmentID, version: 1, deleted: false, fields: fields,
                metadata: Garment(id: operation.garmentID, name: fields.name, category: fields.category,
                    priceGrosz: fields.priceGrosz, imageID: images[operation.operationID] == nil ? nil : operation.operationID,
                    hasCleanedImage: cleanedImages[operation.operationID] != nil, brand: fields.metadata?.brand, colors: fields.metadata?.colors ?? [], seasons: fields.metadata?.seasons ?? []))
        }, wears: Array(wears.values))
    }
    func image(id: UUID, original: Bool) async throws -> Data {
        guard online else { throw URLError(.notConnectedToInternet) }
        return try XCTUnwrap(images[id])
    }
    func save(_ operation: SaveWear) async throws -> SyncWear {
        guard online else { throw URLError(.notConnectedToInternet) }
        for garmentID in operation.wear.garmentIDs {
            XCTAssertTrue(operations.values.contains { $0.garmentID == garmentID && images[$0.operationID] != nil })
        }
        let wear = operation.wear
        let saved = SyncWear(id: wear.id, version: 1, deleted: false, wornOn: wear.wornOn, timezone: wear.timezone, garmentIDs: wear.garmentIDs)
        wears[operation.operationID] = saved
        return saved
    }
}
