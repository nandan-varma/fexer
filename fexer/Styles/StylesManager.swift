import Foundation
import CoreImage
import Observation

@Observable
final class StylesManager {
    var activeStyle: PhotoStyle? = nil
    var styleIntensity: Float = 0.85
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
        return lutFilter
    }

    func selectStyle(_ style: PhotoStyle?) {
        if style?.id == PhotoStyle.none.id {
            activeStyle = nil
        } else {
            activeStyle = style
        }
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isSmartStylesEnabled else { return }
        sceneClassifier.processFrame(pixelBuffer)
        if let suggested = sceneClassifier.suggestedStyle, activeStyle == nil {
            activeStyle = suggested
        }
    }
}
