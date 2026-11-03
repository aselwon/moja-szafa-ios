import XCTest
import UIKit
import ImageIO
@testable import MojaSzafa

@MainActor
final class OutfitExportTests: XCTestCase {
    func testOnlySelectedPhotosAndFixedCaptionCrossShareBoundary() async throws {
        let firstID = UUID(), secondID = UUID(), unrelatedID = UUID()
        let repository = ExportPhotoFixture(photos: [firstID: photo(.red), secondID: photo(.blue), unrelatedID: photo(.green)])
        var outfit = Outfit(name: "Private name 123 PLN", garments: [
            Garment(id: UUID(), name: "Private shirt", priceGrosz: 12300, imageID: firstID),
            Garment(id: UUID(), name: "Private shoes", priceGrosz: 45600, imageID: secondID)
        ])
        let payload = try await OutfitExporter.prepare(outfit, repository: repository)
        let requested = await repository.requested
        XCTAssertEqual(requested, [firstID, secondID])
        XCTAssertEqual(payload.activityItems.count, 2)
        XCTAssertTrue(payload.activityItems[0] is UIImage)
        XCTAssertEqual(payload.activityItems[1] as? String, String(localized: "outfits.export.caption"))
        XCTAssertEqual(payload.image.size, CGSize(width: 1200, height: 1200))
        XCTAssertEqual(payload.image.scale, 1)
        // Metadata-only changes cannot alter exported pixels or text.
        outfit.id = UUID()
        outfit.name = "Another private identifier"
        outfit.garments[0].priceGrosz = 99999
        let changed = try await OutfitExporter.prepare(outfit, repository: repository)
        XCTAssertEqual(payload.image.pngData(), changed.image.pngData())
        XCTAssertEqual(payload.caption, changed.caption)
        let data = try XCTUnwrap(payload.image.pngData())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary as String])
        // The collage includes both selected photos in order, not a screenshot or placeholder.
        XCTAssertEqual(pixel(payload.image, x: 300, y: 600), [255, 0, 0, 255])
        XCTAssertEqual(pixel(payload.image, x: 900, y: 600), [0, 0, 255, 255])
    }

    func testEmptyMissingCorruptAndOfflinePhotosNeverProducePayload() async {
        let id = UUID()
        for outfit in [Outfit(), Outfit(garments: [Garment(id: UUID(), name: "Missing")]),
                       Outfit(garments: [Garment(id: UUID(), name: "Corrupt", imageID: id)])] {
            do {
                _ = try await OutfitExporter.prepare(outfit, repository: ExportPhotoFixture(photos: [id: Data("invalid".utf8)]))
                XCTFail("Incomplete collages must not be shared")
            } catch {}
        }
        let repository = ExportPhotoFixture(photos: [:])
        let outfit = Outfit(garments: [Garment(id: UUID(), name: "Offline", imageID: id)])
        do {
            _ = try await OutfitExporter.prepare(outfit, repository: repository)
            XCTFail("Offline failure must remain retryable")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        await repository.setPhoto(photo(.red), id: id)
        do { _ = try await OutfitExporter.prepare(outfit, repository: repository) }
        catch { XCTFail("Retry should succeed: \(error)") }
    }

    func testCancellationDoesNotProducePayload() async {
        let id = UUID()
        let repository = ExportPhotoFixture(photos: [id: photo(.red)])
        let task = Task {
            try await OutfitExporter.prepare(Outfit(garments: [Garment(id: UUID(), name: "Cancelled", imageID: id)]), repository: repository)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation must not return a payload") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func photo(_ color: UIColor) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private source identifier"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: -CGFloat(x), y: -CGFloat(y), width: 1200, height: 1200))
        }
        return bytes
    }
}

private actor ExportPhotoFixture: WardrobeRepository {
    var photos: [UUID: Data]
    var requested: [UUID] = []
    init(photos: [UUID: Data]) { self.photos = photos }
    func garments() async throws -> [Garment] { XCTFail("Must not fetch the entire wardrobe"); return [] }
    func thumbnail(imageID: UUID) async throws -> Data {
        requested.append(imageID)
        guard let data = photos[imageID] else { throw URLError(.notConnectedToInternet) }
        return data
    }
    func setPhoto(_ data: Data, id: UUID) { photos[id] = data }
}
