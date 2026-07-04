import SwiftUI
import MediaPlayer

/// Adds a zero-size MPVolumeView to the UIKit hierarchy so the system knows
/// the app is managing volume display itself, suppressing the built-in HUD.
///
/// MPVolumeView is deprecated since iOS 17, but no alternative offers the same
/// volume-HUD-suppression behavior.  Keep using it until Apple provides a
/// replacement.
struct VolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
