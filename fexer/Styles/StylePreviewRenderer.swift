import UIKit
import CoreImage

/// Generates style preview thumbnails from a bundled sample image.
final class StylePreviewRenderer {
    static let shared = StylePreviewRenderer()

    private let cache = NSCache<NSString, UIImage>()
    private let renderQueue = DispatchQueue(label: "com.fexer.stylePreview", qos: .userInitiated, attributes: .concurrent)
    private let ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleImage: CIImage

    private init() {
        cache.countLimit = 40
        if let uiImage = UIImage(named: "SamplePreview"), let ci = CIImage(image: uiImage) {
            sampleImage = ci
        } else {
            sampleImage = CIImage.empty()
        }
    }

    /// No-op — previews now use a bundled sample image, not live frames.
    nonisolated func updateFrame(_ pixelBuffer: CVPixelBuffer) {}

    nonisolated func thumbnail(for style: PhotoStyle,
                                size: CGSize = CGSize(width: 120, height: 90),
                                completion: @escaping (UIImage?) -> Void) {
        let key = "\(style.id)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { completion(cached); return }

        let base = sampleImage

        renderQueue.async { [self] in
            var processed = base

            if let (data, dim) = LUTLoader.shared.effectiveLUT(for: style),
               let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace",
                                        parameters: [
                                            "inputImage": base,
                                            "inputCubeDimension": dim,
                                            "inputCubeData": data,
                                            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
                                        ]),
               let output = lutFilter.outputImage {
                processed = output
            }

            let scale = max(size.width / processed.extent.width, size.height / processed.extent.height)
            let scaled = processed.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ox = (scaled.extent.width  - size.width)  / 2
            let oy = (scaled.extent.height - size.height) / 2
            let cropRect = CGRect(x: scaled.extent.minX + ox, y: scaled.extent.minY + oy,
                                  width: size.width, height: size.height)

            guard let cgImage = self.ciContext.createCGImage(scaled, from: cropRect) else {
                completion(nil); return
            }
            let thumb = UIImage(cgImage: cgImage)
            self.cache.setObject(thumb, forKey: key)
            DispatchQueue.main.async { completion(thumb) }
        }
    }
}
