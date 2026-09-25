import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fexer

struct ImageRendererTests {
    private func makeJPEGData() -> Data {
        let size = 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let cgImage = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func gpsDictionary(of data: Data) -> [String: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        return properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
    }

    @Test func embedLocationWritesReadableNorthernWesternCoordinates() async throws {
        let renderer = ImageRenderer()
        let embedded = try await renderer.embedLocation(GeoTag(latitude: 37.7749, longitude: -122.4194, altitude: 15.5), into: makeJPEGData())
        let gps = gpsDictionary(of: embedded)
        #expect(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "N")
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - 37.7749) < 0.0001)
        #expect(gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "W")
        #expect(abs((gps[kCGImagePropertyGPSLongitude as String] as? Double ?? 0) - 122.4194) < 0.0001)
        #expect(abs((gps[kCGImagePropertyGPSAltitude as String] as? Double ?? 0) - 15.5) < 0.0001)
    }

    @Test func embedLocationWritesReadableSouthernEasternCoordinatesWithoutAltitude() async throws {
        let renderer = ImageRenderer()
        let embedded = try await renderer.embedLocation(GeoTag(latitude: -33.8688, longitude: 151.2093, altitude: nil), into: makeJPEGData())
        let gps = gpsDictionary(of: embedded)
        #expect(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S")
        #expect(abs((gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0) - 33.8688) < 0.0001)
        #expect(gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "E")
        #expect(gps[kCGImagePropertyGPSAltitude as String] == nil)
    }

    @Test func embedLocationDoesNotAlterPixelDimensions() async throws {
        let renderer = ImageRenderer()
        let original = makeJPEGData()
        let embedded = try await renderer.embedLocation(GeoTag(latitude: 1, longitude: 1, altitude: nil), into: original)
        let originalImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(original as CFData, nil)!, 0, nil)
        let embeddedImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(embedded as CFData, nil)!, 0, nil)
        #expect(originalImage?.width == embeddedImage?.width)
        #expect(originalImage?.height == embeddedImage?.height)
    }
}
