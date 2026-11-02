import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func require(_ condition: @autoclosure () -> Bool) {
    precondition(condition(), "Image codec acceptance assertion failed")
}
let executable = CommandLine.arguments[1]
func run(_ data: Data, succeeds: Bool) throws -> [String: Data] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: data)
    try input.fileHandleForWriting.close()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    require((process.terminationStatus == 0) == succeeds)
    if !succeeds { return [:] }
    let result = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
    return result.mapValues { Data(base64Encoded: $0)! }
}
func fixture(type: CFString, width: Int, height: Int, frames: Int = 1) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type, frames, nil)!
    let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE_MARKER"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N"]]
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, metadata as CFDictionary) }
    require(CGImageDestinationFinalize(destination))
    return data as Data
}
let jpeg = fixture(type: UTType.jpeg.identifier as CFString, width: 800, height: 400)
let normalized = try run(jpeg, succeeds: true)
for (variant, data) in normalized {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    require(properties[kCGImagePropertyGPSDictionary] == nil)
    require(properties[kCGImagePropertyExifDictionary] == nil)
    require(data.range(of: Data("PRIVATE_MARKER".utf8)) == nil)
    require(CGImageSourceGetType(source)! as String == UTType.png.identifier)
    let width = properties[kCGImagePropertyPixelWidth] as! Int
    let height = properties[kCGImagePropertyPixelHeight] as! Int
    require(height > width) // EXIF orientation was applied before removal.
    require(max(width, height) <= (variant == "thumbnail" ? 384 : 4096))
}
_ = try run(fixture(type: UTType.png.identifier as CFString, width: 8, height: 8), succeeds: true)
_ = try run(Data("not an image".utf8), succeeds: false)
_ = try run(jpeg.prefix(100), succeeds: false)
_ = try run(fixture(type: UTType.gif.identifier as CFString, width: 8, height: 8, frames: 2), succeeds: false)
_ = try run(fixture(type: UTType.png.identifier as CFString, width: 12001, height: 1), succeeds: false)
print("PASS: real decoding, orientation, EXIF/GPS stripping, thumbnails, format and dimension rejection")
