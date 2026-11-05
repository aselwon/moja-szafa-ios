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
                .filter { $0.pathExtension == "jpg" && !FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("completed").path) }
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
        guard !running, !hasPendingImport(id), !hasPendingRecognition(id), let index = drafts.firstIndex(where: { $0.id == id }),
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

    func commitGarmentValue(_ value: GarmentFormValue, for id: UUID,
                            repository: any WardrobeRepository) async throws {
        guard !running, !hasPendingRecognition(id), let draft = drafts.first(where: { $0.id == id }), let file = draft.file else {
            throw PhotoImportError.invalidImage
        }
        var fields = APIv1.GarmentFields(name: value.name, category: value.category,
                                        priceGrosz: value.priceGrosz, availability: .available)
        fields.metadata = .init(colors: value.colors, seasons: value.seasons, pattern: value.pattern,
                                formality: value.formality, brand: value.brand, purchasedOn: value.purchasedOn)
        let intent = directory.appendingPathComponent(id.uuidString).appendingPathExtension("intent")
        let photo = directory.appendingPathComponent(id.uuidString).appendingPathExtension("upload")
        let operation: APIv1.SaveGarment
        if FileManager.default.fileExists(atPath: intent.path) {
            operation = try JSONDecoder().decode(APIv1.SaveGarment.self, from: Data(contentsOf: intent))
            guard operation.garmentID == id, operation.garment == fields else { throw OfflineError.pendingChange }
        } else {
            operation = APIv1.SaveGarment(operationID: UUID(), garmentID: id, baseVersion: nil, garment: fields)
            // Freeze the bytes before persisting the intent; subsequent retries cannot
            // accidentally publish a newly edited image under an already-used ID.
            let photos = try GarmentPhotos(original: PhotoProcessor.read(file), cleaned: draft.editedFile.map { try PhotoProcessor.read($0) })
            try photos.storedData.write(to: photo, options: [.atomic, .completeFileProtection])
            try saveGarmentValue(value, for: id)
            try JSONEncoder().encode(operation).write(to: intent, options: [.atomic, .completeFileProtection])
        }
        running = true
        defer { running = false }
        try await repository.importGarment(operation, photos: GarmentPhotos.read(photo))
        // The durable wardrobe owns the data now. A cleanup crash must not
        // resurrect a draft or enqueue another garment.
        let completed = directory.appendingPathComponent(id.uuidString).appendingPathExtension("completed")
        try Data().write(to: completed, options: [.atomic, .completeFileProtection])
        var cleanupSucceeded = true
        for suffix in ["jpg", "png", "recognition", "json", "upload", "intent"] {
            let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension(suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { cleanupSucceeded = false }
            }
        }
        if cleanupSucceeded { try? FileManager.default.removeItem(at: completed) }
        drafts.removeAll { $0.id == id }
    }

    func hasPendingImport(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.uuidString).appendingPathExtension("intent").path)
    }

    func remove(_ id: UUID) {
        guard !running, !hasPendingImport(id), !hasPendingRecognition(id), let draft = drafts.first(where: { $0.id == id }) else { return }
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

/// Retains the complete result object until the existing closed recognition
/// validator checks it; unknown metadata fields must not disappear in decoding.
indirect enum RecognitionJSON: Codable, Sendable {
    case object([String: RecognitionJSON]), array([RecognitionJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try value.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

struct PhotoRecognitionStatus: Decodable, Sendable {
    let job_id: UUID
    let draft_id: UUID
    let image_id: UUID
    let status: String
    let error_code: String?
    let result: RecognitionJSON?
}
protocol PhotoRecognitionService: Sendable {
    func uploadRecognitionPhoto(draftID: UUID, imageID: UUID, data: Data) async throws
    func enqueueRecognition(draftID: UUID, imageID: UUID, operationID: UUID) async throws -> PhotoRecognitionStatus
    func recognitionResult(draftID: UUID, imageID: UUID, jobID: UUID) async throws -> PhotoRecognitionStatus
    func discardRecognition(draftID: UUID) async throws
}

extension APIClient: PhotoRecognitionService {
    func enqueueRecognition(draftID: UUID, imageID: UUID, operationID: UUID) async throws -> PhotoRecognitionStatus {
        let response: APIv1.Success<PhotoRecognitionStatus> = try await call("api_v1_recognition", [
            "action": "enqueue", "draft_id": draftID.uuidString, "image_id": imageID.uuidString, "operation_id": operationID.uuidString])
        return try checkedRecognition(response.data, draftID: draftID, imageID: imageID)
    }
    func recognitionResult(draftID: UUID, imageID: UUID, jobID: UUID) async throws -> PhotoRecognitionStatus {
        let response: APIv1.Success<PhotoRecognitionStatus> = try await call("api_v1_recognition", [
            "action": "result", "draft_id": draftID.uuidString, "image_id": imageID.uuidString, "job_id": jobID.uuidString])
        guard response.data.job_id == jobID else { throw APIClientError.invalidResponse }
        return try checkedRecognition(response.data, draftID: draftID, imageID: imageID)
    }
    func discardRecognition(draftID: UUID) async throws {
        struct Receipt: Decodable { let discarded: Bool }
        do {
            let response: APIv1.Success<Receipt> = try await call("api_v1_recognition", ["action": "discard", "draft_id": draftID.uuidString])
            guard response.data.discarded else { throw APIClientError.invalidResponse }
        } catch let error as APIv1.Failure where error.code == "not_found" {
            // An upload can fail before creating its private remote draft.
            // Canonical absence completes cleanup; authentication and transport
            // failures must retain the durable cleanup request for a retry.
        }
    }
    private func checkedRecognition(_ value: PhotoRecognitionStatus, draftID: UUID, imageID: UUID) throws -> PhotoRecognitionStatus {
        guard value.draft_id == draftID, value.image_id == imageID,
              ["queued", "running", "succeeded", "cancelled", "dead_letter"].contains(value.status) else { throw APIClientError.invalidResponse }
        if value.status == "succeeded", let result = value.result {
            _ = try GarmentRecognition.decodeDraft(JSONEncoder().encode(result))
        }
        return value
    }
}

private struct PhotoRecognitionIntent: Codable {
    let localID: UUID
    let draftID: UUID
    var imageID: UUID
    let operationID: UUID
    let digest: String
    var jobID: UUID?
}

extension PhotoImportModel {
    private func analysisURL(_ id: UUID, _ suffix: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(suffix)
    }
    func hasPendingRecognition(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: analysisURL(id, "analysis-intent").path)
    }
    private func readAnalysis(_ id: UUID) throws -> PhotoRecognitionIntent? {
        let url = analysisURL(id, "analysis-intent")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try PhotoProcessor.read(url)
        guard data.count <= 4096 else { throw PhotoImportError.invalidImage }
        let intent = try JSONDecoder().decode(PhotoRecognitionIntent.self, from: data)
        guard intent.localID == id else { throw PhotoImportError.invalidImage }
        return intent
    }
    private func writeAnalysis(_ intent: PhotoRecognitionIntent) throws {
        try JSONEncoder().encode(intent).write(to: analysisURL(intent.localID, "analysis-intent"), options: [.atomic, .completeFileProtection])
    }
    /// Release local editing immediately, but keep a durable private remote-cleanup
    /// request. A delayed result for the old remote draft will never be applied.
    private func finishAnalysis(_ intent: PhotoRecognitionIntent) throws {
        try JSONEncoder().encode(intent.draftID).write(to: analysisURL(intent.draftID, "analysis-cleanup"), options: [.atomic, .completeFileProtection])
        for suffix in ["analysis-intent", "analysis-upload"] {
            let url = analysisURL(intent.localID, suffix)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func continueManually(_ id: UUID) {
        guard !running else { return }
        do {
            if let intent = try readAnalysis(id) { try finishAnalysis(intent) }
            if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].status = "import.ready" }
            message = nil
        } catch { message = "import.storageFailed" }
    }
    func cleanRecognitionDrafts(using service: any PhotoRecognitionService) async {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "analysis-cleanup" {
            do {
                let id = try JSONDecoder().decode(UUID.self, from: PhotoProcessor.read(file))
                guard file.deletingPathExtension().lastPathComponent == id.uuidString else { continue }
                try await service.discardRecognition(draftID: id)
                try FileManager.default.removeItem(at: file)
            } catch { /* Retry on next visit; the server also expires private drafts. */ }
        }
    }
    func startRecognition(_ id: UUID, using service: any PhotoRecognitionService, maxPolls: Int = 10, pollDelay: Duration = .seconds(2)) {
        guard !running, !hasPendingImport(id), let draft = drafts.first(where: { $0.id == id }), let source = draft.displayFile else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { running = false; task = nil }
            do {
                var intent: PhotoRecognitionIntent
                if let existing = try readAnalysis(id) { intent = existing }
                else {
                    let bytes = try PhotoProcessor.read(source)
                    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    intent = PhotoRecognitionIntent(localID: id, draftID: UUID(), imageID: UUID(), operationID: UUID(), digest: digest)
                    try bytes.write(to: analysisURL(id, "analysis-upload"), options: [.atomic, .completeFileProtection])
                    try writeAnalysis(intent)
                }
                let bytes = try PhotoProcessor.read(analysisURL(id, "analysis-upload"))
                guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == intent.digest else { throw PhotoImportError.invalidImage }
                if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].status = "recognition.pending" }
                if intent.jobID == nil {
                    do {
                        try await service.uploadRecognitionPhoto(draftID: intent.draftID, imageID: intent.imageID, data: bytes)
                    } catch PhotoUploadError.expired {
                        intent.imageID = UUID()
                        try writeAnalysis(intent)
                        try await service.uploadRecognitionPhoto(draftID: intent.draftID, imageID: intent.imageID, data: bytes)
                    }
                    try Task.checkCancellation()
                    let receipt = try await service.enqueueRecognition(draftID: intent.draftID, imageID: intent.imageID, operationID: intent.operationID)
                    guard receipt.draft_id == intent.draftID, receipt.image_id == intent.imageID else { throw APIClientError.invalidResponse }
                    intent.jobID = receipt.job_id
                    try writeAnalysis(intent)
                }
                for attempt in 0..<max(1, min(maxPolls, 30)) {
                    try Task.checkCancellation()
                    guard let job = intent.jobID else { throw APIClientError.invalidResponse }
                    let status = try await service.recognitionResult(draftID: intent.draftID, imageID: intent.imageID, jobID: job)
                    try Task.checkCancellation()
                    guard status.job_id == job, status.draft_id == intent.draftID, status.image_id == intent.imageID else { throw APIClientError.invalidResponse }
                    if status.status == "succeeded" {
                        guard let result = status.result else { throw APIClientError.invalidResponse }
                        let data = try JSONEncoder().encode(result)
                        _ = try GarmentRecognition.decodeDraft(data)
                        // Both edits and manual confirmation are locked while this
                        // durable request owns the current local draft revision.
                        try data.write(to: analysisURL(id, "recognition"), options: [.atomic, .completeFileProtection])
                        try finishAnalysis(intent)
                        if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].status = "recognition.ready" }
                        message = nil
                        await cleanRecognitionDrafts(using: service)
                        return
                    }
                    if ["cancelled", "dead_letter"].contains(status.status) {
                        try finishAnalysis(intent)
                        message = "recognition.failed"
                        return
                    }
                    guard ["queued", "running"].contains(status.status) else { throw APIClientError.invalidResponse }
                    if attempt + 1 < maxPolls { try await Task.sleep(for: pollDelay) }
                }
                message = "recognition.pending"
            } catch {
                message = Task.isCancelled ? "recognition.pending" : "recognition.failed"
            }
        }
    }
}
