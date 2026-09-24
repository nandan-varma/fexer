import Foundation
import ImageIO

nonisolated struct ExifField: RawRepresentable, Hashable {
    let rawValue: String
    static let make = ExifField(rawValue: "Make")
    static let model = ExifField(rawValue: "Model")
    static let iso = ExifField(rawValue: "ISO")
    static let shutterSpeed = ExifField(rawValue: "ShutterSpeed")
    static let aperture = ExifField(rawValue: "Aperture")
    static let focalLength = ExifField(rawValue: "FocalLength")
    static let whiteBalance = ExifField(rawValue: "WhiteBalance")
    static let flash = ExifField(rawValue: "Flash")
    static let dateTime = ExifField(rawValue: "DateTime")
    static let gpsLatitude = ExifField(rawValue: "GPSLatitude")
    static let gpsLongitude = ExifField(rawValue: "GPSLongitude")
    static let exposureProgram = ExifField(rawValue: "ExposureProgram")
    static let meteringMode = ExifField(rawValue: "MeteringMode")
    static let orientation = ExifField(rawValue: "Orientation")
}

enum ExifReader {
    nonisolated static func read(from data: Data) -> [ExifField: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }

        var result: [ExifField: String] = [:]

        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake as String] as? String { result[.make] = make }
            if let model = tiff[kCGImagePropertyTIFFModel as String] as? String { result[.model] = model }
            if let dt = tiff[kCGImagePropertyTIFFDateTime as String] as? String { result[.dateTime] = dt }
            if let ori = tiff[kCGImagePropertyTIFFOrientation as String] { result[.orientation] = "\(ori)" }
        }

        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first { result[.iso] = "ISO \(iso)" }
            if let ss = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                result[.shutterSpeed] = ss < 1 ? "1/\(Int(round(1/ss)))s" : "\(ss)s"
            }
            if let ap = exif[kCGImagePropertyExifFNumber as String] as? Double { result[.aperture] = "f/\(ap)" }
            if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double { result[.focalLength] = "\(Int(fl))mm" }
            if let wb = exif[kCGImagePropertyExifWhiteBalance as String] as? Int { result[.whiteBalance] = wb == 0 ? "Auto" : "Manual" }
            if let flash = exif[kCGImagePropertyExifFlash as String] as? Int { result[.flash] = "\(flash)" }
        }

        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
               let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String {
                result[.gpsLatitude] = String(format: "%.5f° %@", lat, latRef)
            }
            if let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double,
               let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String {
                result[.gpsLongitude] = String(format: "%.5f° %@", lon, lonRef)
            }
        }

        return result
    }

    // nonisolated: pure ImageIO work, called from detached post-capture tasks off MainActor.
    nonisolated static func embedStyleTag(in data: Data, styleName: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let uti = CGImageSourceGetType(source)
        else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return nil }

        var metadata: [String: Any] = [:]
        if let existing = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            metadata = existing
        }

        let xmpKey = "{XMP}"
        var xmp = metadata[xmpKey] as? [String: Any] ?? [:]
        xmp["fexer:AppliedStyle"] = styleName
        metadata[xmpKey] = xmp

        CGImageDestinationAddImageFromSource(dest, source, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}
