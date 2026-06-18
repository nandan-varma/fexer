/// Flip a flag to `true` to unlock the feature in the UI.
/// All flags default to false except the core capture pipeline.
enum FeatureFlags {
    // Core — always on
    static let manualControls = true   // ISO, shutter, WB, EV panel
    static let histogram      = true   // RGB+Luma color graph
    static let cameraFlip     = true   // Front / back toggle
    static let lensSwitch     = true   // 0.5× / 1× / 3× lens buttons
    static let tapToFocus     = true
    static let pinchToZoom    = true

    // Disabled for v1 — flip to true to test
    static let shootingModes  = false
    static let stylePicker    = false
    static let gridOverlay    = false
    static let focusPeaking   = false
    static let zebraStripes   = false
    static let levelIndicator = false
    static let galleryView    = false
    static let settingsView   = false
    static let quickAccessBar = false
    static let focusSlider    = true
}
