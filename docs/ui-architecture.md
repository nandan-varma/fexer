# UI Architecture — Views, Persistence, QuickAccessBar

Scope: view organization, CameraView layer composition, @AppStorage persistence, the
QuickAccessBar extension point, shared UI components, and overlay views. The full file tree
is in [docs/project-overview.md](project-overview.md).

## View organization

- `CameraView.swift` is the main camera UI: layer composition, @AppStorage keys, gesture
  routing. Split across `CameraView+Capture.swift` / `+ShootingModes.swift` /
  `+ShutterButton.swift` / `+LensSwitcher.swift` / `+Lifecycle.swift`.
- `ViewfinderView.swift` — MTKView + overlay composition.
- `ReviewView.swift` / `ReviewCarouselView.swift` — post-capture review (shared controls live
  in `SupportingTypes/SharedUIComponents.swift`).
- `EditView.swift` — non-destructive editor sliders ([docs/style-system.md](style-system.md)).
- `GalleryView.swift` — Photo Library grid. `SettingsView.swift` — preferences.
  `OnboardingView.swift` — first-run permissions. `SplashView.swift` — launch animation.

## Persistence: @AppStorage keys

**@AppStorage keys ARE the persistence layer** — there is no separate UserDefaults wrapper.
`CameraView` holds the keys and syncs them to `CameraManager`/`CameraViewModel` via
`.onChange` modifiers at the bottom of `mainContent`.

**Adding a new persisted setting:** declare it in `CameraView`, mirror it in `SettingsView`
using the **same key string**, and add an `.onChange` handler to apply it.

Current keys (40, verified from `CameraView.swift`):

- **Overlays**: `showHistogram`, `showGrid`, `gridType`, `showFocusPeaking`, `showZebra`,
  `showLevelIndicator`, `showFalseColor`, `showWaveform`, `showVectorscope`, `showEVIndicator`,
  `isCleanViewActive`
- **Capture**: `isBracketingEnabled`, `bracketEVStep`, `isWBBracketEnabled`, `wbBracketKStep`,
  `selfTimerDelay`, `selfTimerRepeat`, `burstCount`, `isProRAWEnabled`, `defaultCaptureFormat`
  (default `"HEIF"`), `focusPeakingColor`, `isHDREnabled`, `isTrapFocusEnabled`,
  `isOpticalZoomLocked`
- **Video**: `videoFrameRate`, `videoResolution`, `videoColorSpace`, `stabilizationMode`
- **Location / media flow**: `isLocationEnabled`, `torchLevel`, `showReviewAfterShot`,
  `showGallery`, `showStylePicker`
- **Other**: `cropRatio`, `timelapseInterval`, `longExposureDuration`, `volumeButtonBehavior`,
  `watermarkText`, `zebraHighThreshold`, `zebraLowThreshold`

### Processor flag sync — two entry points

- `syncOverlaysToProcessor(...)` — full sync: flags + peaking color + **LUT filter**. Call
  after changing anything that affects the LUT (style change, false color toggle).
- `syncFlagsToProcessor(...)` — flags + peaking color only, **no LUT**. Cheaper path for
  overlay toggles (grid, histogram, waveform, …) and rapid value scrubs (zebra thresholds).

Both take the AppStorage values as parameters — `CameraViewModel` does not own the keys.

## QuickAccessBar (top icon bar, 50 pt)

Two sections:

1. **Fixed settings gear** — always the first button, `onShowSettings` callback; not
   customisable and cannot be removed.
2. **Scrollable customisable items** — driven by `appState.quickAccessItems:
   [QuickAccessItem]`.

**Adding a new item requires:** a new `case` in `QuickAccessItem` (Models/ShootingMode.swift),
a `systemImageName`, and handling in `isActive`, `badge`, `handleTap`, and `iconName` (if the
icon is dynamic) inside `QuickAccessBar`. Update the defaults in
`AppState.loadQuickAccessItems()`.

Registered items (23, verified): `.flash`, `.torch`, `.timer`, `.grid`, `.histogram`,
`.flipCamera`, `.focusPeaking`, `.zebra`, `.levelIndicator`, `.livePhoto`, `.format`,
`.falseColor`, `.bracketAEB`, `.afMode`, `.wbBracket`, `.waveform`, `.vectorscope`,
`.cleanView`, `.opticalZoomLock`, `.trapFocus`, `.presets`, `.hdr`, `.metering`.

**Counter-rotation:** icons and badges rotate together as a unit using
`.rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))`. The frame is on
the `Image` INSIDE the `ZStack` (not outside) so `.topTrailing` alignment anchors the badge
relative to the full button bounds before rotation. The background `RoundedRectangle` is
applied after rotation and stays portrait-aligned.

## Shared UI components

`Views/SupportingTypes/SharedUIComponents.swift` is the single home for repeated review /
gallery UI — keep new shared controls here (this file exists to eliminate duplication):

- `CircleIconButton` — circular SF Symbol button.
- `ReviewDeleteButton` — review-screen delete action.
- `SharePhotoLink` — share link for a captured photo.
- `ReviewGestures` (private `ViewModifier`) + `reviewGestures` view extension — review
  swipe/dismiss gestures.
- `AccessDeniedView` — photo-library permission-denied state.

Also: `Views/StylePicker/SliderThumb.swift` — reusable thumb for the style-adjustment
sliders.

## Overlays (Views/Overlays/)

`HistogramView`, `WaveformView`, `VectorscopeView`, `LevelIndicatorView`,
`AudioLevelMeterView`, `EVOffsetIndicator`, `GridOverlayView`
(`strokeGrid(context:color:verticals:horizontals:)` + `gridLines(count:width:height:)`
helpers), `FocusPeakingOverlay`, `ZebraOverlay`, `GestureHintOverlay`
(`BrightnessEVIndicator`, `BrightnessHintView`).

All overlays must be constrained to the preview area, not the full screen
(`letterboxBarHeight` — see [docs/camera-pipeline.md](camera-pipeline.md)).

## Counter-rotation

The app is portrait-locked (see [docs/project-overview.md](project-overview.md)). Any UI
element that should stay upright in landscape applies
`.rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))`.
`DeviceOrientationTracker.start()` / `stop()` are called from `CameraView+Lifecycle.swift`.
