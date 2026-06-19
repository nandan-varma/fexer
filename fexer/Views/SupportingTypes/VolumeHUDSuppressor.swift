import SwiftUI
import MediaPlayer

/// Adds a zero-size MPVolumeView to the UIKit hierarchy so the system knows
/// the app is managing volume display itself, suppressing the built-in HUD.
struct VolumeHUDSuppressor: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
