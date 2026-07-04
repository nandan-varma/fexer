import UIKit
import CoreImage

/// Generates style preview thumbnails from a bundled sample image.
final class StylePreviewRenderer {
    static let shared = StylePreviewRenderer()

    nonisolated(unsafe) private let cache = NSCache<NSString, UIImage>()
    private let renderQueue = DispatchQueue(label: "com.fexer.stylePreview", qos: .userInitiated, attributes: .concurrent)
    private let ciContext: CIContext = .shared
    private let sampleImage: CIImage

    private init() {
        cache.countLimit = 40
        if let uiImage = UIImage(named: "SamplePreview"), let ci = CIImage(image: uiImage) {
            sampleImage = ci
        } else {
            sampleImage = CIImage.empty()
        }
    }

    nonisolated func originalImage(size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let keyStr = "__original__-\(Int(size.width))x\(Int(size.height))"
        let key = keyStr as NSString
        if let cached = cache.object(forKey: key) { DispatchQueue.main.async { completion(cached) }; return }

        let base = sampleImage
        guard base.extent.width > 0 && base.extent.height > 0 else { completion(nil); return }

        renderQueue.async { [self] in
            let cacheKey = keyStr as NSString
            let scale = max(size.width / base.extent.width, size.height / base.extent.height)
            let scaled = base.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ox = (scaled.extent.width  - size.width)  / 2
            let oy = (scaled.extent.height - size.height) / 2
            let cropRect = CGRect(x: scaled.extent.minX + ox, y: scaled.extent.minY + oy,
                                  width: size.width, height: size.height)
            guard let cgImage = self.ciContext.createCGImage(scaled, from: cropRect) else {
                completion(nil); return
            }
            let image = UIImage(cgImage: cgImage)
            self.cache.setObject(image, forKey: cacheKey)
            DispatchQueue.main.async { completion(image) }
        }
    }

    nonisolated func thumbnail(for style: PhotoStyle,
                                size: CGSize = CGSize(width: 120, height: 90),
                                completion: @escaping (UIImage?) -> Void) {
        let keyStr = "\(style.id)-\(Int(size.width))x\(Int(size.height))"
        let key = keyStr as NSString
        if let cached = cache.object(forKey: key) { DispatchQueue.main.async { completion(cached) }; return }

        let base = sampleImage
        guard base.extent.width > 0 && base.extent.height > 0 else { completion(nil); return }

        renderQueue.async { [self] in
            let cacheKey = keyStr as NSString
            var processed = base

            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            if let (data, dim) = LUTLoader.shared.effectiveLUT(for: style),
               let lutFilter = CIFilter(name: "CIColorCubeWithColorSpace",
                                          parameters: [
                                              "inputImage": base,
                                              "inputCubeDimension": dim,
                                              "inputCubeData": data,
                                              "inputColorSpace": sRGB
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
            self.cache.setObject(thumb, forKey: cacheKey)
            DispatchQueue.main.async { completion(thumb) }
        }
    }
}
