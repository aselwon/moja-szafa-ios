import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// The share boundary contains only newly rendered pixels and a fixed localized caption.
/// Never pass domain objects, user-entered names, source URLs or original image bytes.
struct OutfitExportPayload {
    let image: UIImage
    let pngData: Data
    var caption: String { String(localized: "outfits.export.caption") }
    var itemProviders: [NSItemProvider] {
        let photo = NSItemProvider()
        let bytes = pngData
        photo.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        return [photo, NSItemProvider(object: caption as NSString)]
    }
}

enum OutfitExportError: Error { case missingPhotos, encodingFailed }

@MainActor
enum OutfitExporter {
    static func prepare(_ outfit: Outfit, repository: any WardrobeRepository) async throws -> OutfitExportPayload {
        guard (1...100).contains(outfit.garments.count), outfit.garments.allSatisfy({ $0.imageID != nil }) else {
            throw OutfitExportError.missingPhotos
        }
        var photos: [UIImage] = []
        // Sequential requests and bounded decoding avoid loading full-resolution originals.
        for garment in outfit.garments {
            try Task.checkCancellation()
            guard let imageID = garment.imageID else { throw OutfitExportError.missingPhotos }
            let bytes = try await repository.thumbnail(imageID: imageID)
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                  ] as CFDictionary) else { throw OutfitExportError.missingPhotos }
            photos.append(UIImage(cgImage: bitmap))
        }
        let size = CGSize(width: 1200, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let columns = Int(ceil(sqrt(Double(photos.count))))
            let rows = (photos.count + columns - 1) / columns
            let cell = min(1168 / CGFloat(columns), 1168 / CGFloat(rows))
            for (index, photo) in photos.enumerated() {
                let bounds = CGRect(x: (1200 - CGFloat(columns) * cell) / 2 + CGFloat(index % columns) * cell + 8,
                                    y: (1200 - CGFloat(rows) * cell) / 2 + CGFloat(index / columns) * cell + 8,
                                    width: cell - 16, height: cell - 16)
                let scale = min(bounds.width / photo.size.width, bounds.height / photo.size.height)
                let fitted = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                                      width: fitted.width, height: fitted.height))
            }
        }
        // UIKit's UIImage encoding adds EXIF/TIFF properties. Encode the new
        // bitmap directly and share these exact bytes, without source metadata
        // or a later UIImage conversion at the activity boundary.
        let bytes = NSMutableData()
        guard let bitmap = image.cgImage,
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw OutfitExportError.encodingFailed
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw OutfitExportError.encodingFailed }
        return OutfitExportPayload(image: image, pngData: try pixelOnlyPNG(bytes as Data))
    }

    private static func pixelOnlyPNG(_ data: Data) throws -> Data {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard data.starts(with: signature) else { throw OutfitExportError.encodingFailed }
        // ImageIO adds an eXIf chunk even when given no metadata. Keep only
        // PNG image/color chunks from our freshly rendered bitmap; discard
        // EXIF and all text/time/other ancillary metadata. Whole chunks retain
        // their original CRCs, so the pixel stream is never re-encoded.
        let allowed = Set(["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB"])
        var result = signature
        var offset = signature.count
        while data.count - offset >= 12 {
            let length = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - offset - 12 else { throw OutfitExportError.encodingFailed }
            let end = offset + length + 12
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if allowed.contains(type) { result.append(data[offset..<end]) }
            if type == "IEND" {
                guard length == 0, end == data.count else { throw OutfitExportError.encodingFailed }
                return result
            }
            offset = end
        }
        throw OutfitExportError.encodingFailed
    }
}

struct OutfitExportView: View {
    let outfit: Outfit
    let repository: any WardrobeRepository
    @Environment(\.dismiss) private var dismiss
    @State private var payload: OutfitExportPayload?
    @State private var failed = false
    @State private var attempt = 0
    @State private var sharing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("outfits.export.privacy")
                    if let payload {
                        Image(uiImage: payload.image).resizable().scaledToFit()
                            .accessibilityLabel(Text("outfits.export.preview"))
                        Text(verbatim: payload.caption)
                        Button("outfits.export.share", systemImage: "square.and.arrow.up") { sharing = true }
                            .buttonStyle(.borderedProminent)
                    } else if failed {
                        Text("outfits.export.failed")
                        Button("common.retry") { attempt += 1 }
                    } else {
                        ProgressView("common.loading")
                    }
                }.padding()
            }
            .navigationTitle("outfits.export.title")
            .toolbar { Button("outfits.cancel") { dismiss() } }
            .task(id: attempt) {
                failed = false
                do {
                    let result = try await OutfitExporter.prepare(outfit, repository: repository)
                    try Task.checkCancellation()
                    payload = result
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
            .sheet(isPresented: $sharing) {
                if let payload { OutfitActivitySheet(payload: payload) }
            }
        }
    }
}

struct OutfitActivitySheet: UIViewControllerRepresentable {
    let payload: OutfitExportPayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItemsConfiguration: UIActivityItemsConfiguration(itemProviders: payload.itemProviders))
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
