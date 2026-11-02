import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Standalone trusted backend codec. Build on macOS; never trust client metadata.
enum DecodeError: Error { case invalid }
func normalizeImage(_ data: Data) throws -> [String: String] {
    guard !data.isEmpty, data.count <= 20 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetStatus(source) == .statusComplete,
          CGImageSourceGetCount(source) == 1,
          let type = CGImageSourceGetType(source) as String?,
          [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.webP.identifier].contains(type),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0, width <= 12_000, height <= 12_000,
          width * height <= 40_000_000 else { throw DecodeError.invalid }
    // Actually decode, apply orientation, and redraw into a fresh sRGB bitmap.
    // No source properties (EXIF/GPS/IPTC/XMP or embedded profiles) are copied.
    func render(maximum: Int) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: color,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DecodeError.invalid }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let clean = context.makeImage() else { throw DecodeError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { throw DecodeError.invalid }
        CGImageDestinationAddImage(destination, clean, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 20 * 1024 * 1024 else { throw DecodeError.invalid }
        return output as Data
    }
    return try ["original": render(maximum: 4096).base64EncodedString(),
                "thumbnail": render(maximum: 384).base64EncodedString()]
}

// Read one extra byte to reject oversized input without unbounded allocation.
do {
    let limit = 20 * 1024 * 1024
    var data = Data()
    while data.count <= limit {
        let chunk = FileHandle.standardInput.readData(ofLength: min(64 * 1024, limit + 1 - data.count))
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    let result = try normalizeImage(data)
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
} catch {
    FileHandle.standardError.write(Data("image_decode_failed\n".utf8))
    exit(1)
}
