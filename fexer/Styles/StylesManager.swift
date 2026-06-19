import Foundation
import CoreImage
import Observation

struct StyleAdjustments: Equatable {
    var exposure: Float = 0      // EV stops, -1.5 … +1.5
    var contrast: Float = 0      // delta, -0.5 … +0.5
    var saturation: Float = 0    // delta, -1.0 … +1.0 (ignored for BW styles)
    var warmth: Float = 0        // -1 = cool, +1 = warm
}

@Observable
final class StylesManager {
    var activeStyle: PhotoStyle? = nil
    var styleIntensity: Float = 0.85
    var adjustments = StyleAdjustments()
    var suggestedStyle: PhotoStyle?

    private let lutLoader = LUTLoader.shared
    private let lutFilter = LUTFilter()
    private let sceneClassifier = SceneClassifier()

    var allStyles: [StyleCategory: [PhotoStyle]] {
        Dictionary(grouping: PhotoStyle.catalog, by: \.category)
    }

    var isSmartStylesEnabled: Bool = false {
        didSet { sceneClassifier.isEnabled = isSmartStylesEnabled }
    }

    // Called from CaptureProcessor on sessionQueue — returns filter configured for this frame
    func activeLUTFilter() -> LUTFilter? {
        guard let style = activeStyle else { return nil }
        guard let (data, dim) = lutLoader.effectiveLUT(for: style) else { return nil }
        lutFilter.setStyle(name: style.name, data: data, dimension: dim)
        lutFilter.inputIntensity = styleIntensity

        let p = StyleTransforms.params(for: style)
        lutFilter.isBW = (p.saturation == 0)
        lutFilter.adjExposure   = adjustments.exposure
        lutFilter.adjContrast   = adjustments.contrast
        lutFilter.adjSaturation = lutFilter.isBW ? 0 : adjustments.saturation
        lutFilter.adjWarmth     = adjustments.warmth

        return lutFilter
    }

    /// Returns a fresh LUTFilter configured for the current style, for baking into a still capture.
    /// Creates a new instance each call to avoid racing with the shared preview-pipeline filter.
    func makeCaptureFilter() -> LUTFilter? {
        guard let style = activeStyle else { return nil }
        guard let (data, dim) = lutLoader.effectiveLUT(for: style) else { return nil }
        let filter = LUTFilter()
        filter.setStyle(name: style.name, data: data, dimension: dim)
        filter.inputIntensity = styleIntensity
        let p = StyleTransforms.params(for: style)
        filter.isBW = (p.saturation == 0)
        filter.adjExposure   = adjustments.exposure
        filter.adjContrast   = adjustments.contrast
        filter.adjSaturation = filter.isBW ? 0 : adjustments.saturation
        filter.adjWarmth     = adjustments.warmth
        return filter
    }

    func selectStyle(_ style: PhotoStyle?) {
        let newStyle = (style?.id == PhotoStyle.none.id) ? nil : style
        if newStyle?.id != activeStyle?.id {
            adjustments = StyleAdjustments()
        }
        activeStyle = newStyle
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isSmartStylesEnabled else { return }
        sceneClassifier.processFrame(pixelBuffer)
        suggestedStyle = sceneClassifier.suggestedStyle
        if let suggested = sceneClassifier.suggestedStyle, activeStyle == nil {
            activeStyle = suggested
        }
    }
}
