import Combine
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
    private let accountID: UUID?
    private var accountDeleted: Bool {
        accountID.map { UserDefaults.standard.bool(forKey: "deletion.accepted.\($0)") } ?? false
    }

    static func directory(for accountID: UUID) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("PhotoDrafts").appendingPathComponent(accountID.uuidString)
    }

    static func deleteDrafts(directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
    private let processor = PhotoProcessor()
    private var task: Task<Void, Never>?

    init(directory: URL, accountID: UUID? = nil) {
        self.directory = directory
        self.accountID = accountID
        guard !accountDeleted else { return }
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
        guard !accountDeleted, !running, !loaders.isEmpty else { return }
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
                    // The durable marker fences an import that resumed after deletion.
                    guard !accountDeleted else { throw CancellationError() }
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
        guard !accountDeleted, !running, let index = drafts.firstIndex(where: { $0.id == id }),
              let original = drafts[index].file else { return false }
        let destination = original.deletingPathExtension().appendingPathExtension("png")
        do {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
            drafts[index].editedFile = destination
            return true
        } catch {
            message = "import.storageFailed"
            return false
        }
    }

    func remove(_ id: UUID) {
        guard !running, let draft = drafts.first(where: { $0.id == id }) else { return }
        do {
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
