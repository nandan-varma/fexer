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

    func requestThumbnail(for style: PhotoStyle) {
        guard thumbnails[style.id] == nil else { return }
        StylePreviewRenderer.shared.thumbnail(for: style) { [weak self] image in
            guard let image else { return }
            self?.thumbnails[style.id] = image
        }
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        StylePreviewRenderer.shared.updateFrame(pixelBuffer)
        stylesManager.processFrame(pixelBuffer)
    }
}
