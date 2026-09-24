import AVFoundation
import CoreImage
import ImageIO
import OSLog
import UIKit

/// Fused post-capture image pipeline: depth blur + LUT bake + desqueeze + crop + watermark
/// + XMP style tag in a single decode/encode pass.
///
/// `nonisolated` — runs on detached tasks off the AVFoundation callback thread so
/// `isCapturing` clears immediately after sensor readout.
nonisolated enum CaptureImagePipeline {

    struct Options {
        var isRaw = false
        var captureFilter: LUTFilter?
        var isAnamorphic = false
        var cropRatio: CropRatio = .full
        var watermark = ""
        var activeStyle: PhotoStyle?
        var depthData: AVDepthData?
        /// Photo connection angle at capture time: 90=portrait, 0=landscapeLeft, 180=landscapeRight, 270=upsideDown
        var captureAngle: CGFloat = 90
        var isLandscapeCapture: Bool { captureAngle == 0 || captureAngle == 180 }
    }

    // MARK: - Full still-capture pass

    static func process(rawData: Data, options: Options) -> Data {
        let needsLUT          = options.captureFilter != nil && !options.isRaw
        let needsDesqueeze    = options.isAnamorphic && !options.isRaw
        let needsCrop         = !options.isRaw && options.cropRatio != .full
        let needsWatermark    = !options.isRaw && !options.watermark.isEmpty
        let needsPortraitBlur = options.depthData != nil && !options.isRaw
        let needsPixelWork = needsLUT || needsDesqueeze || needsCrop || needsWatermark || needsPortraitBlur

        guard needsPixelWork,
              let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              let uti = CGImageSourceGetType(source),
              let ciImage = CIImage(data: rawData, options: [.applyOrientationProperty: true])
        else {
            // Fast path (no pixel work) or decode failure: add the XMP style tag via
            // source-copy if needed — no full re-encode. RAW containers are never rewritten.
            if !options.isRaw, let style = options.activeStyle {
                return ExifReader.embedStyleTag(in: rawData, styleName: style.name) ?? rawData
            }
            return rawData
        }

        var out = ciImage

        // Portrait depth blur — applied before LUT so the grade sits on top of the blurred image
        if needsPortraitBlur, let depth = options.depthData {
            out = depthBlurred(out, depth: depth, source: source)
        }

        if needsLUT, let filter = options.captureFilter {
            filter.inputImage = out
            out = filter.outputImage ?? out
        }

        // Apply 2× horizontal desqueeze to match what the preview showed
        if needsDesqueeze {
            out = out.transformed(by: CGAffineTransform(scaleX: 2.0, y: 1.0))
        }

        // Crop in CI space — a free transform on the lazy graph, avoids a second decode/encode cycle
        if needsCrop, let aspect = options.cropRatio.portraitAspect {
            // Invert portrait aspect for landscape captures (photo connection rotated pixels to landscape)
            let cropAspect = options.isLandscapeCapture ? 1.0 / aspect : aspect
            out = centerCropped(out, toAspect: cropAspect)
        }

        let props = metadataProps(source: source, activeStyle: options.activeStyle)
        let encoded = needsWatermark
            ? encodeWithWatermark(out, watermark: options.watermark, uti: uti, props: props)
            : encodeDirect(out, uti: uti, props: props)
        return encoded ?? rawData
    }

    // MARK: - Pipeline stages

    private static func depthBlurred(_ image: CIImage, depth: AVDepthData, source: CGImageSource) -> CIImage {
        guard let blurFilter = CIFilter(name: "CIDepthBlurEffect") else { return image }
        let converted = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let srcProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientationValue = srcProps?[kCGImagePropertyOrientation as String] as? UInt32 ?? 1
        let photoOrientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        let disparityCI = CIImage(cvPixelBuffer: converted.depthDataMap).oriented(photoOrientation)
        blurFilter.setValue(image, forKey: kCIInputImageKey)
        blurFilter.setValue(disparityCI, forKey: "inputDisparityImage")
        blurFilter.setValue(Float(2.8), forKey: "inputAperture")
        guard let blurOutput = blurFilter.outputImage else { return image }
        return blurOutput.cropped(to: image.extent)
    }

    /// Original image properties with orientation normalized to 1 (pixels are already upright
    /// after `.applyOrientationProperty` decode) and the XMP style tag merged in.
    private static func metadataProps(source: CGImageSource, activeStyle: PhotoStyle?) -> [String: Any] {
        var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let style = activeStyle {
            var xmp = props["{XMP}"] as? [String: Any] ?? [:]
            xmp["fexer:AppliedStyle"] = style.name
            props["{XMP}"] = xmp
        }
        return props
    }

    /// Fast path: encode directly from CIImage (GPU→hardware encoder, no 48MB CGImage buffer).
    /// CGImageDestinationAddImageFromSource WITHOUT kCGImageDestinationLossyCompressionQuality
    /// performs a lossless metadata-only write — compressed pixels are copied unchanged.
    private static func encodeDirect(_ image: CIImage, uti: CFString, props: [String: Any]) -> Data? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let ciOpts: [CIImageRepresentationOption: Any] = [qualityKey: 0.92]
        let utiStr = uti as String
        let encodedData: Data?
        if utiStr == "public.heic" || utiStr == "public.heif" {
            encodedData = CIContext.shared.heifRepresentation(of: image, format: .RGBA8, colorSpace: sRGB, options: ciOpts)
        } else {
            encodedData = CIContext.shared.jpegRepresentation(of: image, colorSpace: sRGB, options: ciOpts)
        }
        guard let ciEncoded = encodedData,
              let ciSrc = CGImageSourceCreateWithData(ciEncoded as CFData, nil)
        else { return nil }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, ciSrc, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    /// Watermark path: needs a CGImage to draw text onto before re-encoding.
    private static func encodeWithWatermark(_ image: CIImage, watermark: String, uti: CFString, props: [String: Any]) -> Data? {
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CIContext.shared.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
        else { return nil }
        let stamped = watermarked(cgImage, text: watermark)
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, uti, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, stamped, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Shared building blocks

    /// Center-crops a CIImage to the given width/height aspect ratio.
    static func centerCropped(_ image: CIImage, toAspect aspect: CGFloat) -> CIImage {
        let ext = image.extent
        let currentAspect = ext.width / ext.height
        let cropRect: CGRect
        if aspect <= currentAspect {
            let newW = ext.height * aspect
            cropRect = CGRect(x: ext.origin.x + (ext.width - newW) / 2, y: ext.origin.y,
                              width: newW, height: ext.height)
        } else {
            let newH = ext.width / aspect
            cropRect = CGRect(x: ext.origin.x, y: ext.origin.y + (ext.height - newH) / 2,
                              width: ext.width, height: newH)
        }
        return image.cropped(to: cropRect)
    }

    /// Draws the watermark text in the bottom-right corner. UIGraphicsImageRenderer is
    /// documented thread-safe, so this may run off-main.
    static func watermarked(_ cgImage: CGImage, text: String) -> CGImage {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
            let fontSize = max(24, size.width * 0.022)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65)
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let strSize = str.size()
            let padding = fontSize * 1.4
            str.draw(at: CGPoint(x: size.width - strSize.width - padding,
                                 y: size.height - strSize.height - padding))
        }
        return rendered.cgImage ?? cgImage
    }
}
