import UIKit
import CoreImage

/// Generates style preview thumbnails from the current live frame in parallel.
final class StylePreviewRenderer {
    static let shared = StylePreviewRenderer()

    private let cache = NSCache<NSString, UIImage>()
    private let renderQueue = DispatchQueue(label: "com.fexer.stylePreview", qos: .userInitiated, attributes: .concurrent)
    private let ciContext: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()
    private var lastFramePixelBuffer: CVPixelBuffer?
    private var lastFrameLuma: Float = -1

    private init() {
        cache.countLimit = 40
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        let luma = averageLuminance(of: pixelBuffer)
        if abs(luma - lastFrameLuma) > 0.1 {
            cache.removeAllObjects()
            lastFrameLuma = luma
        }
        lastFramePixelBuffer = pixelBuffer
    }

    func thumbnail(for style: PhotoStyle, size: CGSize = CGSize(width: 120, height: 90), completion: @escaping (UIImage?) -> Void) {
        let key = "\(style.id)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        guard let buffer = lastFramePixelBuffer else {
            completion(nil)
            return
        }

        renderQueue.async { [self] in
            let image = CIImage(cvPixelBuffer: buffer)
            var processed = image

            if let lutFileName = style.lutFileName,
               let (data, dim) = LUTLoader.shared.load(filename: lutFileName),
               let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace",
                                         parameters: [
                                            "inputImage": image,
                                            "inputCubeDimension": dim,
                                            "inputCubeData": data,
                                            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
                                         ]),
               let output = lutFilter.outputImage {
                processed = output
            }

            let scale = max(size.width / processed.extent.width, size.height / processed.extent.height)
            let scaled = processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let cropped = scaled.cropped(to: CGRect(origin: .zero, size: size))

            guard let cgImage = self.ciContext.createCGImage(cropped, from: cropped.extent) else {
                completion(nil)
                return
            }

            let thumbnail = UIImage(cgImage: cgImage)
            self.cache.setObject(thumbnail, forKey: key)
            DispatchQueue.main.async { completion(thumbnail) }
        }
    }

    private func averageLuminance(of buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        var sum: Float = 0
        let step = 32
        var count = 0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let offset = y * bytesPerRow + x * 4
                let b = Float(pixels[offset])
                let g = Float(pixels[offset + 1])
                let r = Float(pixels[offset + 2])
                sum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }
}
