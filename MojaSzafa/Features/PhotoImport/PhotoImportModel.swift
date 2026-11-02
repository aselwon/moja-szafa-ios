import Combine
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
                        Draft(id: $0, status: "import.ready", file: url)
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

    func remove(_ id: UUID) {
        guard !running, let draft = drafts.first(where: { $0.id == id }) else { return }
        do {
            if let file = draft.file { try FileManager.default.removeItem(at: file) }
            drafts.removeAll { $0.id == id }
        } catch { message = "import.storageFailed" }
    }
}
