import SwiftUI
import Observation

@Observable
final class StylesViewModel {
    let stylesManager: StylesManager

    var selectedCategory: StyleCategory = .film
    var isBeforeAfterActive = false
    var thumbnails: [UUID: UIImage] = [:]
    var isPickerExpanded = false

    init(stylesManager: StylesManager) {
        self.stylesManager = stylesManager
    }

    var stylesForSelectedCategory: [PhotoStyle] {
        stylesManager.allStyles[selectedCategory] ?? []
    }

    var activeStyle: PhotoStyle? {
        get { stylesManager.activeStyle }
        set { stylesManager.selectStyle(newValue) }
    }

    var styleIntensity: Float {
        get { stylesManager.styleIntensity }
        set { stylesManager.styleIntensity = newValue }
    }

    var adjustments: StyleAdjustments {
        get { stylesManager.adjustments }
        set { stylesManager.adjustments = newValue }
    }

    var activeStyleIsBW: Bool {
        guard let style = stylesManager.activeStyle else { return false }
        return StyleTransforms.params(for: style).saturation == 0
    }

    func requestThumbnail(for style: PhotoStyle) {
        guard thumbnails[style.id] == nil else { return }
        StylePreviewRenderer.shared.thumbnail(for: style) { [weak self] image in
            guard let image else { return }
            self?.thumbnails[style.id] = image
        }
    }

    /// Called from sessionQueue via CaptureProcessor.onPixelBuffer (~1/s).
    nonisolated func onFrameAvailable(_ pixelBuffer: CVPixelBuffer) {
        StylePreviewRenderer.shared.updateFrame(pixelBuffer)
        stylesManager.processFrame(pixelBuffer)
        Task { @MainActor [weak self] in self?.retryPendingThumbnailsOnce() }
    }

    private var _hasRetriedThumbnails = false
    private func retryPendingThumbnailsOnce() {
        guard !_hasRetriedThumbnails else { return }
        _hasRetriedThumbnails = true
        for style in stylesManager.allStyles.values.flatMap({ $0 }) {
            requestThumbnail(for: style)
        }
    }
}
