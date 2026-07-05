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
    private let sceneClassifier = SceneClassifier()

    let allStyles: [StyleCategory: [PhotoStyle]] = Dictionary(grouping: PhotoStyle.catalog, by: \.category)

    var isSmartStylesEnabled: Bool = false {
        didSet { sceneClassifier.isEnabled = isSmartStylesEnabled }
    }

    // MARK: - LUT Filter Configuration

    private func configureFilter(_ filter: LUTFilter, for style: PhotoStyle) {
        guard let (data, dim) = lutLoader.effectiveLUT(for: style) else { return }
        filter.setStyle(name: style.name, data: data, dimension: dim)
        filter.inputIntensity = styleIntensity
        let p = StyleTransforms.params(for: style)
        filter.isBW = (p.saturation == 0)
        filter.adjExposure   = adjustments.exposure
        filter.adjContrast   = adjustments.contrast
        filter.adjSaturation = filter.isBW ? 0 : adjustments.saturation
        filter.adjWarmth     = adjustments.warmth
    }

    /// Returns a fresh LUTFilter for the live preview pipeline.
    /// A new instance per call (style changes only, not per frame) — a shared instance would
    /// race: MainActor reconfigures its properties while sessionQueue reads them per frame.
    func activeLUTFilter() -> LUTFilter? {
        makeCaptureFilter()
    }

    /// Returns a fresh LUTFilter configured for the current style, for baking into a still capture.
    /// Creates a new instance each call so capture and preview never share mutable filter state.
    func makeCaptureFilter() -> LUTFilter? {
        guard let style = activeStyle else { return nil }
        let filter = LUTFilter()
        configureFilter(filter, for: style)
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
    }
}
