import Combine
import CryptoKit
import CoreImage
import Vision
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoImportError: Error {
    case tooLarge, invalidImage
}

/// Runs decoding off the UI executor; downsampling avoids full-resolution bitmaps.
actor PhotoProcessor {
    static let maxBytes = 10 * 1024 * 1024

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw PhotoImportError.tooLarge }
        return data
    }

    func normalize(_ data: Data) throws -> Data {
        guard data.count <= Self.maxBytes else { throw PhotoImportError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type as String),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PhotoImportError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PhotoImportError.invalidImage }
        // Only pixels and compression settings: never copy GPS, EXIF or source metadata.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= Self.maxBytes else {
            throw PhotoImportError.invalidImage
        }
        return output as Data
    }
}

@MainActor
final class PhotoImportModel: ObservableObject {
    struct Draft: Identifiable {
        let id: UUID
        var status: String
        var file: URL?
        var editedFile: URL?
        var displayFile: URL? { editedFile ?? file }
    }
    @Published private(set) var drafts: [Draft] = []
    @Published private(set) var running = false
    @Published var message: String?
    private let directory: URL
    private let processor = PhotoProcessor()
    private var task: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            drafts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jpg" }
                .compactMap { url in
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent).map {
                        Draft(id: $0, status: "import.ready", file: url,
                              editedFile: FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("png").path)
                                ? url.deletingPathExtension().appendingPathExtension("png") : nil)
                    }
                }
        } catch { message = "import.storageFailed" }
    }

    func start(_ loaders: [@MainActor () async throws -> Data]) {
        guard !running, !loaders.isEmpty else { return }
        running = true
        let ids = loaders.map { _ in UUID() }
        drafts += ids.map { Draft(id: $0, status: "import.waiting") }
        task = Task { [weak self] in
            guard let self else { return }
            for (id, loader) in zip(ids, loaders) {
                guard let index = drafts.firstIndex(where: { $0.id == id }) else { continue }
                do {
                    try Task.checkCancellation()
                    drafts[index].status = "import.processing"
                    let input = try await loader()
                    try Task.checkCancellation()
                    let output = try await processor.normalize(input)
                    try Task.checkCancellation()
                    let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
                    try output.write(to: file, options: [.atomic, .completeFileProtection])
                    drafts[index].file = file
                    drafts[index].status = "import.ready"
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        drafts[index].status = "import.cancelled"
                    } else if case PhotoImportError.tooLarge = error {
                        drafts[index].status = "import.tooLarge"
                    } else {
                        drafts[index].status = "import.failed"
                    }
                }
            }
            running = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Atomic replacement leaves the previous selection intact if storage fails.
    func acceptEdit(_ data: Data, for id: UUID) -> Bool {
        guard !running, let index = drafts.firstIndex(where: { $0.id == id }),
              let original = drafts[index].file else { return false }
        let destination = original.deletingPathExtension().appendingPathExtension("png")
        do {
            let recognition = directory.appendingPathComponent(id.uuidString).appendingPathExtension("recognition")
            if FileManager.default.fileExists(atPath: recognition.path) { try FileManager.default.removeItem(at: recognition) }
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            drafts[index].editedFile = destination
            return true
        } catch {
            message = "import.storageFailed"
            return false
        }
    }

    /// Integration boundary for an owner-scoped completed image job, never a provider call.
    /// Store suggestions separately so analysis cannot overwrite manually entered metadata.
    func acceptRecognition(_ data: Data, for id: UUID) throws {
        guard !running, drafts.contains(where: { $0.id == id && $0.file != nil }) else {
            throw PhotoImportError.invalidImage
        }
        _ = try GarmentRecognition.decodeDraft(data)
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("recognition")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func recognitionSuggestions(for id: UUID) throws -> GarmentSuggestions? {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("recognition")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try GarmentRecognition.decodeDraft(Data(contentsOf: url)).suggestions
    }

    func garmentValue(for id: UUID) throws -> GarmentFormValue? {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GarmentFormValue.self, from: Data(contentsOf: url))
    }

    func saveGarmentValue(_ value: GarmentFormValue, for id: UUID) throws {
        guard !running, drafts.contains(where: { $0.id == id && $0.file != nil }) else {
            throw PhotoImportError.invalidImage
        }
        let url = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }

    func remove(_ id: UUID) {
        guard !running, let draft = drafts.first(where: { $0.id == id }) else { return }
        do {
            let metadata = directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
            let recognition = directory.appendingPathComponent(id.uuidString).appendingPathExtension("recognition")
            if FileManager.default.fileExists(atPath: recognition.path) { try FileManager.default.removeItem(at: recognition) }
            if let edited = draft.editedFile { try FileManager.default.removeItem(at: edited) }
            if let file = draft.file { try FileManager.default.removeItem(at: file) }
            drafts.removeAll { $0.id == id }
        } catch { message = "import.storageFailed" }
    }
}

/// Fractions of the upright, metadata-free original; position spans the remaining space.
struct PhotoCrop: Equatable, Sendable {
    var width: Double = 1
    var height: Double = 1
    var horizontal: Double = 0.5
    var vertical: Double = 0.5

    func rect(width pixelsWide: Int, height pixelsHigh: Int) throws -> CGRect {
        guard [width, height, horizontal, vertical].allSatisfy({ $0.isFinite }),
              (0.1...1).contains(width), (0.1...1).contains(height),
              (0...1).contains(horizontal), (0...1).contains(vertical) else {
            throw PhotoImportError.invalidImage
        }
        return CGRect(x: horizontal * (1 - width) * Double(pixelsWide),
                      y: vertical * (1 - height) * Double(pixelsHigh),
                      width: width * Double(pixelsWide), height: height * Double(pixelsHigh)).integral
            .intersection(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    }
}

actor PhotoEditorProcessor {
    func crop(_ data: Data, to crop: PhotoCrop) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = image.cropping(to: try crop.rect(width: image.width, height: image.height)) else {
            throw PhotoImportError.invalidImage
        }
        return try Self.png(cropped)
    }

    func removeBackground(_ data: Data) throws -> Data {
        let handler = VNImageRequestHandler(data: data)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw PhotoImportError.invalidImage
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances,
                                                   from: handler, croppedToInstancesExtent: false)
        let image = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(image, from: image.extent) else {
            throw PhotoImportError.invalidImage
        }
        return try Self.png(output)
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PhotoImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoImportError.invalidImage }
        return data as Data
    }
}

@MainActor
final class PhotoEditorModel: ObservableObject {
    @Published var crop = PhotoCrop() { didSet { preview = nil; message = nil } }
    @Published private(set) var preview: Data?
    @Published private(set) var running = false
    @Published private(set) var message: String?
    private let original: Data
    private let processor = PhotoEditorProcessor()
    private let segment: @Sendable (Data) async throws -> Data

    init(original: Data, segment: @escaping @Sendable (Data) async throws -> Data = {
        try await PhotoEditorProcessor().removeBackground($0)
    }) {
        self.original = original
        self.segment = segment
    }

    func render(removeBackground: Bool) async {
        guard !running else { return }
        running = true
        message = nil
        let requestedCrop = crop
        defer { running = false }
        do {
            let cropped = try await processor.crop(original, to: requestedCrop)
            try Task.checkCancellation()
            guard crop == requestedCrop else { return }
            preview = cropped
            if removeBackground {
                do {
                    let cleaned = try await segment(cropped)
                    try Task.checkCancellation()
                    guard crop == requestedCrop else { return }
                    preview = cleaned
                } catch {
                    guard !Task.isCancelled, crop == requestedCrop else { preview = nil; return }
                    message = "edit.segmentationFailed"
                }
            }
        } catch {
            preview = nil
            if !Task.isCancelled { message = "edit.failed" }
        }
    }
}

/// Advisory comparison only. No identity, merge or deletion decisions use this score.
actor DuplicatePhotoDetector {
    struct Fingerprint: Sendable {
        let digest: Data
        let pixels: [UInt8]

        func resembles(_ other: Self) -> Bool {
            if digest == other.digest { return true }
            // Mean RGB distance on an 8×8 white-backed image. Conservative, but not
            // invariant to a different camera angle or background; false positives are possible.
            let distance = zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            return distance <= pixels.count * 8
        }
    }

    func fingerprint(_ data: Data) throws -> Fingerprint {
        guard data.count <= PhotoProcessor.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64
              ] as CFDictionary) else { throw PhotoImportError.invalidImage }
        var rgba = [UInt8](repeating: 255, count: 8 * 8 * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8,
                bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard rendered else { throw PhotoImportError.invalidImage }
        return Fingerprint(digest: Data(SHA256.hash(data: data)),
                           pixels: rgba.enumerated().filter { $0.offset % 4 != 3 }.map(\.element))
    }

    func fingerprint(file: URL) throws -> Fingerprint {
        try fingerprint(PhotoProcessor.read(file))
    }
}

struct DuplicatePhotoMatch: Identifiable {
    let id: UUID
    let name: String?
    let image: Data
}

struct DuplicatePhotoReview {
    var matches: [DuplicatePhotoMatch] = []
    var incomplete = false
}

extension PhotoImportModel {
    /// Both sources are scoped to the current account by WardrobeView. Fingerprints
    /// live only for this review; no image data or hashes are sent to a third party.
    func duplicateReview(for id: UUID, repository: (any WardrobeRepository)?) async -> DuplicatePhotoReview {
        var review = DuplicatePhotoReview()
        let detector = DuplicatePhotoDetector()
        guard let file = drafts.first(where: { $0.id == id })?.file,
              let target = try? await detector.fingerprint(file: file) else {
            review.incomplete = true
            return review
        }
        for draft in drafts where draft.id != id && draft.file != nil {
            if Task.isCancelled { review.incomplete = true; return review }
            do {
                let fingerprint = try await detector.fingerprint(file: draft.file!)
                if target.resembles(fingerprint), review.matches.count < 5 {
                    review.matches.append(DuplicatePhotoMatch(id: draft.id,
                        name: (try? garmentValue(for: draft.id))?.name,
                        image: try PhotoProcessor.read(draft.file!)))
                }
            } catch { review.incomplete = true }
        }
        guard let repository else { review.incomplete = true; return review }
        do {
            for archived in [false, true] {
                var query = WardrobeQuery()
                query.archived = archived
                var offset = 0
                repeat {
                    try Task.checkCancellation()
                    let page = try await repository.page(query: query, offset: offset, limit: 40)
                    if page.cached { review.incomplete = true }
                    for garment in page.items {
                        try Task.checkCancellation()
                        guard let imageID = garment.imageID else { continue }
                        do {
                            let data = try await repository.thumbnail(imageID: imageID)
                            let fingerprint = try await detector.fingerprint(data)
                            if target.resembles(fingerprint), review.matches.count < 5,
                               !review.matches.contains(where: { $0.id == garment.id }) {
                                review.matches.append(DuplicatePhotoMatch(id: garment.id, name: garment.name, image: data))
                            }
                        } catch { review.incomplete = true }
                    }
                    guard let next = page.nextOffset else { break }
                    guard next > offset else { review.incomplete = true; break }
                    offset = next
                } while true
            }
        } catch { review.incomplete = true }
        return review
    }
}
