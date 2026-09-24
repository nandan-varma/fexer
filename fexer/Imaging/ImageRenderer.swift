import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageRenderer {
    private var cubes: [String: CubeLUT] = [:]
    private var lastAdjustment: (EditRecipe, CubeLUT?)?

    func loadCube(from url: URL) throws -> CubeLUT {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 16 * 1024 * 1024 else { throw AppIssue.decodingFailed }
        return try CubeLUT.parse(String(contentsOf: url, encoding: .utf8))
    }

    func prepare(_ edit: EditRecipe) throws -> RenderRecipe {
        let valid = edit.validated
        let style = PhotoStyle.find(valid.styleID)
        var cube: CubeLUT?
        if let filename = style.file {
            if let cached = cubes[filename] { cube = cached }
            else {
                guard let url = Bundle.main.url(forResource: filename, withExtension: "cube") else {
                    throw AppIssue("Style unavailable", "This style couldn’t be loaded. Try another style.")
                }
                let loaded = try CubeLUT.parse(String(contentsOf: url, encoding: .utf8))
                cubes[filename] = loaded
                cube = loaded
            }
        }
        let adjusted: CubeLUT?
        if let lastAdjustment, lastAdjustment.0.colors == valid.colors, lastAdjustment.0.curves == valid.curves {
            adjusted = lastAdjustment.1
        } else {
            adjusted = ColorMath.adjustmentCube(valid)
            lastAdjustment = (valid, adjusted)
        }
        return RenderRecipe(edit: valid, styleCube: cube, adjustmentCube: adjusted)
    }

    func preview(data: Data, edit: EditRecipe, dimension: Int = 1400) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
              ] as CFDictionary) else { throw AppIssue.decodingFailed }
        let result = ImagePipeline.apply(CIImage(cgImage: thumb), recipe: try prepare(edit))
        try Task.checkCancellation()
        guard let image = ImagePipeline.context.createCGImage(result, from: result.extent) else { throw AppIssue.exportFailed }
        return image
    }

    func export(data: Data, edit: EditRecipe, format: PhotoFormat) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let input = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw AppIssue.decodingFailed }
        let image = ImagePipeline.apply(input, recipe: try prepare(edit))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let encoded: Data?
        if format == .heif {
            encoded = ImagePipeline.context.heifRepresentation(of: image, format: .RGBA8, colorSpace: ImagePipeline.colorSpace, options: [quality: 0.95])
        } else {
            encoded = ImagePipeline.context.jpegRepresentation(of: image, colorSpace: ImagePipeline.colorSpace, options: [quality: 0.95])
        }
        guard let encoded, let encodedSource = CGImageSourceCreateWithData(encoded as CFData, nil),
              let type = CGImageSourceGetType(encodedSource) else { throw AppIssue.exportFailed }
        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        metadata[kCGImagePropertyOrientation as String] = 1
        metadata[kCGImagePropertyPixelWidth as String] = Int(image.extent.width)
        metadata[kCGImagePropertyPixelHeight as String] = Int(image.extent.height)
        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Fexer"
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { throw AppIssue.exportFailed }
        CGImageDestinationAddImageFromSource(destination, encodedSource, 0, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppIssue.exportFailed }
        return output as Data
    }

    func thumbnailJPEG(data: Data, edit: EditRecipe) throws -> Data {
        let image = try preview(data: data, edit: edit, dimension: 480)
        guard let result = ImagePipeline.context.jpegRepresentation(of: CIImage(cgImage: image), colorSpace: ImagePipeline.colorSpace) else {
            throw AppIssue.exportFailed
        }
        return result
    }
}
