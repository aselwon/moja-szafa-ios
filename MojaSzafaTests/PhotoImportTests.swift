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

    private func finish(_ model: PhotoImportModel) async {
        let deadline = Date().addingTimeInterval(10)
        while model.running && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.running, "Import did not finish")
    }
}
