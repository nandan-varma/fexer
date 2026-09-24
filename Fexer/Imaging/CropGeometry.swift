import CoreGraphics
import Foundation

/// Shared by preview and export; all coordinates here use Core Image's bottom-left origin.
enum CropGeometry {
    static func crop(in extent: CGRect, aspect: Double?, zoom: Double, x: Double, y: Double) -> CGRect {
        guard extent.width > 0, extent.height > 0, !extent.isInfinite, !extent.isNull else { return .zero }
        let ratio = (aspect ?? extent.width / extent.height).bounded(0.1...10, fallback: 1)
        let scale = zoom.bounded(1...6, fallback: 1)
        let width = min(extent.width, extent.height * ratio) / scale
        let height = width / ratio
        // x/y represent travel across the available overflow, matching the UI exactly.
        return CGRect(x: extent.minX + (extent.width - width) * x.bounded(0...1, fallback: 0.5),
                      y: extent.minY + (extent.height - height) * (1 - y.bounded(0...1, fallback: 0.5)),
                      width: width, height: height)
    }

    static func straightenedSize(_ size: CGSize, radians: Double) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let angle = abs(radians.bounded(-.pi / 4 ... .pi / 4))
        let cosine = cos(angle), sine = sin(angle), aspect = size.width / size.height
        let height = min(size.width / (aspect * cosine + sine), size.height / (aspect * sine + cosine))
        return CGSize(width: height * aspect, height: height)
    }

    /// Convert a point on an aspect-fill portrait preview into native sensor coordinates.
    static func focusPoint(_ point: CGPoint, view: CGSize, image: CGSize, mirrored: Bool) -> CGPoint {
        guard view.width > 0, view.height > 0, image.width > 0, image.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let scale = max(view.width / image.width, view.height / image.height)
        let visibleWidth = view.width / scale, visibleHeight = view.height / scale
        let normalizedX = ((image.width - visibleWidth) / 2 + point.x / scale) / image.width
        let normalizedY = ((image.height - visibleHeight) / 2 + point.y / scale) / image.height
        return CGPoint(x: Double(normalizedY).bounded(0...1), y: Double(mirrored ? normalizedX : 1 - normalizedX).bounded(0...1))
    }
}
