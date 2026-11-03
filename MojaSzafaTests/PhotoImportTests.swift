import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import MojaSzafa

@MainActor
final class PhotoImportTests: XCTestCase {
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

    func testDeletionRemovesOriginalAndEditAndFencesDelayedImport() async throws {
        let accountID = UUID()
        let key = "deletion.accepted.\(accountID)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = PhotoImportModel(directory: directory, accountID: accountID)
        let bytes = try fixture()
        try bytes.write(to: directory.appendingPathComponent("original.jpg"))
        try bytes.write(to: directory.appendingPathComponent("edit.png"))
        var release: CheckedContinuation<Data, Never>?
        model.start([{ await withCheckedContinuation { release = $0 } }])
        while release == nil { await Task.yield() }
        UserDefaults.standard.set(true, forKey: key)
        try PhotoImportModel.deleteDrafts(directory: directory)
        try PhotoImportModel.deleteDrafts(directory: directory)
        release?.resume(returning: bytes)
        while model.running { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        model.start([{ bytes }])
        XCTAssertFalse(model.running)
        _ = PhotoImportModel(directory: directory, accountID: accountID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
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

    private func finish(_ model: PhotoImportModel) async {
        let deadline = Date().addingTimeInterval(10)
        while model.running && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.running, "Import did not finish")
    }
}
