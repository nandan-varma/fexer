# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build for device (no signing required for verification)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project fexer.xcodeproj -scheme fexer \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build

# Check only for errors (pipe-friendly)
... build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# Run all unit tests (Simulator — no camera required)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project fexer.xcodeproj -scheme fexer \
  -destination "platform=iOS Simulator,name=iPhone 17" test \
  2>&1 | grep -E "error:|Executed|passed|failed"

# Run a single test class
... test -only-testing:fexerTests/EditStateTests 2>&1 | grep -E "error:|passed|failed"

# Lint (enforced in CI as --strict, so warnings are errors)
swiftlint lint --strict
```

**Deployment target is iOS 26.5.** No `#available` guards are needed for any AVFoundation, SwiftUI, or Swift concurrency API introduced before that. Use the latest symbol names directly (e.g. `AVCaptureDevice.wasConnectedNotification`, not the deprecated `.AVCaptureDeviceWasConnected`).

**Camera does not work in Simulator.** All meaningful testing requires a physical iOS device. Unit tests for models/utilities (no camera dependency) are in `Tests/fexerTests/` — the test target is already configured in the scheme. The root-level `fexerTests/fexerTests.swift` is an Xcode stub and is not part of the test suite; ignore it.

SourceKit shows many false-positive errors (UIKit types "unavailable in macOS", cross-file references "not found") because it indexes against the macOS SDK. Ignore them; `xcodebuild` against the iOS SDK is the truth.

## Project Layout

```
fexer/
├── App/                          # AppState.swift
├── Camera/                       # CameraManager, CaptureProcessor, filters, CameraPreview
├── Models/                       # ShootingMode, CaptureSettings, CapturedPhoto, EditState, VideoSettings
├── ViewModels/                   # CameraViewModel, StylesViewModel, GalleryViewModel
├── Utilities/                    # PermissionsManager, CaptureService, HapticManager,
│                                 # ExifReader, HistogramCalculator, LUTLoader, CIContext+Shared,
│                                 # CapturePresetsManager, DeviceOrientationTracker
├── Styles/                       # StylesManager, LUTFilter, StyleTransforms, SceneClassifier,
│                                 # StylePreviewRenderer
├── Views/
│   ├── CameraView.swift          # Main camera UI (1100+ lines)
│   ├── ViewfinderView.swift      # MTKView + overlay composition
│   ├── ReviewView.swift          # Post-capture review
│   ├── EditView.swift            # Non-destructive editor
│   ├── GalleryView.swift         # Photo Library grid
│   ├── SettingsView.swift        # Preferences
│   ├── OnboardingView.swift      # First-run permissions
│   ├── SplashView.swift          # Launch animation (aperture iris)
│   ├── QuickAccessBar.swift      # Customizable bottom toolbar
│   ├── ApertureLogoView.swift    # Programmatic aperture animation
│   ├── Overlays/                 # Histogram, Waveform, Vectorscope, LevelIndicator,
│   │                             # GridOverlay, FocusPeakingOverlay, ZebraOverlay,
│   │                             # GestureHintOverlay
│   ├── ControlsPanel/            # ManualControlsPanel, VerticalDialSlider, ISOSlider,
│   │                             # ShutterSlider, WhiteBalanceSlider, FocusSlider,
│   │                             # AutoToggleButton
│   ├── StylePicker/              # StylePickerView, StyleCategoryView, StyleThumbnailView,
│   │                             # StyleBeforeAfterView, StyleAdjustmentsRow
│   └── SupportingTypes/          # CapturePhotoDelegate, ShutterButtonStyle, VolumeHUDSuppressor,
│                                 # LUTImporterView
├── Resources/LUTs/               # 21× .cube LUT files
└── Tests/fexerTests/             # CameraManagerTests, ViewModelTests, UtilitiesTests
```

## Architecture

### Threading model — the critical invariant

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set, so every class is `@MainActor` by default. The two exceptions are the camera pipeline classes, which run on a private GCD queue:

```
com.fexer.session  (sessionQueue, .userInteractive)
  └── CameraManager.configureSession / all setXxx() calls
  └── CaptureProcessor.captureOutput(_:didOutput:) — AVFoundation delegate
```

**Rule:** AVFoundation calls (`lockForConfiguration`, `setExposureModeCustom`, etc.) must stay on `sessionQueue`. Any mutation of `@Observable` properties that SwiftUI reads must cross back with `Task { @MainActor in ... }`. Never call `UIView.setNeedsDisplay` from `sessionQueue` — use the MTKView's continuous render mode instead (`isPaused = false`, `enableSetNeedsDisplay = false`).

**`nonisolated(unsafe)` pattern:** `CameraManager` is `@MainActor` by default (via `SWIFT_DEFAULT_ACTOR_ISOLATION`), but its recording-pipeline vars (`assetWriter`, `videoWriterInput`, `audioWriterInput`, `pixelBufferAdaptor`, `isWaitingToRecord`, `pendingRecordingLocation`, `pendingRecordingStyleName`, `_captureBusy`) are read and written exclusively on `sessionQueue`. Mark these `nonisolated(unsafe)` and serialize all access through `sessionQueue` — do not let Swift's actor checker treat them as MainActor state.

Classes with explicit `nonisolated` methods that may be called from non-MainActor contexts: `StylePreviewRenderer` (all public methods), `StylesViewModel.onFrameAvailable`. These use `OSAllocatedUnfairLock` for internal thread safety rather than actor isolation.

### Camera pipeline (frame path)

```
AVCaptureVideoDataOutput
  → CaptureProcessor.captureOutput (sessionQueue)
      ├── [1] FalseColorFilter (CIColorKernel) — if enabled; skips LUT + zebra
      ├── [2] LUTFilter (CIColorCubeWithColorSpace) — skipped when false color active
      ├── [3] FocusPeakingFilter (CIColorKernel) — optional, always on top
      ├── [4] ZebraFilter (CIColorKernel) — optional, skipped when false color active
      └── CIImage stored in imageLock (OSAllocatedUnfairLock)
            ↓
CameraPreview.Coordinator.draw(in: MTKView) — continuous 60fps
```

**Pipeline order rationale:** False color must see the ungraded signal (diagnostic tool), LUT is the creative grade, peaking and zebra are analysis tools drawn on top of whatever the user is monitoring.

All mutable state in `CaptureProcessor` that crosses the sessionQueue/MainActor boundary uses `OSAllocatedUnfairLock`: `imageLock`, `lutFilterLock`, `peakingColorLock`, `flagsLock`, `zebraTimeLock`, `anamorphicLock`, `longExpActiveLock`. The single shared `CIContext(mtlDevice:)` is never recreated; recreating it per-frame is expensive.

Video frames arrive in landscape orientation. `configureVideoRotation()` sets `connection.videoRotationAngle = 90` immediately after `session.commitConfiguration()` to deliver portrait-upright frames. This must also be called after `flipCamera()`. The rotation setup is deferred ~150ms after `startRunning()` to allow AVFoundation stabilization and prevent Fig error -12710.

#### Tap-to-focus coordinate mapping

The 90° rotation means AVFoundation's coordinate space has swapped axes relative to the portrait screen:

```swift
// In CameraPreview.Coordinator.handleTap:
normalized = CGPoint(x: point.y / size.height, y: 1 - point.x / size.width)

// Inverse (to recover screen position for the focus square in ViewfinderView):
screenPoint = CGPoint(x: (1 - normalized.y) * geo.size.width,
                      y: normalized.x * geo.size.height)
```

Swapping x/y when recovering screen position is intentional — do not "simplify" it.

### Lens switching

**Session always uses a physical camera** — never a virtual multi-lens device (`builtInTripleCamera`, `builtInDualCamera`, etc.). Virtual devices return `false` for `isLockingFocusWithCustomLensPositionSupported` and `isExposureModeSupported(.custom)`, which silently blocks all manual controls.

`buildBackLensMap()` queries the virtual device **for discovery only** (never adding it to the session), extracts the constituent physical cameras and their optical factors relative to wide-angle = 1×, and stores the result in `backLenses: [LensOption]`. This is called once in `configureSession()`.

`configureSession()` starts on `AVCaptureDevice.default(.builtInWideAngleCamera, …, position: .back)`. `switchToCamera(_ lens: LensOption)` swaps the video device input to a different physical camera, updates `activeLensOpticalFactor`, and resets digital zoom to 1×.

`CameraView+LensSwitcher.swift` drives the lens-switcher row from `backLenses`. The active button is identified by `lens.device == cameraManager.currentDevice`. The live optical zoom label = `currentZoomFactor × activeLensOpticalFactor`. The ZoomDial (long-press) controls digital zoom within the current physical lens; optical label range = `[opticalFactor × minDigitalZoom … opticalFactor × maxDigitalZoom]`.

`flipCamera()` restores the back camera to the wide-angle (`backLenses.first { $0.opticalFactor == 1.0 }?.device`) and the front camera uses `bestCamera(for: .front)` (TrueDepth → wide-angle, both physical).

### Key classes

| Class | Thread | Owns |
|---|---|---|
| `CameraManager` | `@Observable`, properties read on MainActor, mutations dispatched to `sessionQueue` | `AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`, KVO observations, `previewImageSize`, `backLenses`, `activeLensOpticalFactor`, `discoveredCameras` |
| `CaptureProcessor` | `sessionQueue` | Per-frame CI filter chain, histogram computation (every 3rd frame), `OSAllocatedUnfairLock`-protected `latestImage`, `onPixelBuffer` callback (fires on first frame, then every 60th) |
| `CameraViewModel` | `@MainActor` | UI gesture state, overlay toggles, histogram data, self-timer, AE lock toggle, burst/timelapse state |
| `StylesManager` | `@Observable` | LUT catalog, active style, `SceneClassifier`; `activeLUTFilter()` falls back to procedural generation |
| `StylesViewModel` | `@Observable` | Thumbnail cache, wires `CaptureProcessor.onPixelBuffer` → `StylePreviewRenderer` |
| `GalleryViewModel` | `@Observable` | Photo Library fetch, PHImageManager, PHPhotoLibraryChangeObserver |
| `AppState` | `@Observable`, singleton | Screen routing (`currentScreen`), quick-access bar order |

### Rendering

`CameraPreview` is a `UIViewRepresentable` wrapping `MTKView`. The `Coordinator` implements `MTKViewDelegate`. Two render modes depending on `cropRatio`:

- **`.full`**: aspect-fit (`scale = min(scaleX, scaleY)`), composited over black background — produces black bars inside the MTKView
- **Non-full**: aspect-fill (`scale = max(scaleX, scaleY)`), `bounds:` parameter center-crops — SwiftUI letterbox bars are decorative crop guides only; the MTKView still renders full-frame

```swift
ciContext.render(scaled, to: drawable.texture, commandBuffer: commandBuffer,
                 bounds: cropRect,   // ← offset into scaled image, NOT CGRect.zero
                 colorSpace: sRGB)
```

### Letterbox/overlay positioning

All viewfinder overlays (grid, histogram, level indicator, timer countdown) must be constrained to the actual preview area, not the full screen. `CameraView.letterboxBarHeight` computes the inset:

- **Crop modes**: `barH = (screen.height - screen.width/aspect) / 2`
- **Full mode**: uses `cameraManager.previewImageSize` (set on first frame via `CaptureProcessor.onPreviewSizeKnown`) to compute the aspect-fit inset using the image aspect ratio — avoids pixel/point unit mismatch

`CameraPreview.Coordinator.previewBarHeight(viewSize:)` mirrors this logic at the UIKit level to guard tap-to-focus and brightness-swipe gestures from firing inside the black bars.

### AE Lock

`captureSettings.isAELocked` is the **single source of truth** — it is set/cleared by `lockAutoExposure()` / `unlockAutoExposure()` / `setAutoExposure()` on `sessionQueue`, then posted to `MainActor`. `CameraViewModel.isAELocked` is a computed property that reads through to `captureSettings`; it has no stored state. This prevents AEL badge and slider state from drifting out of sync with hardware.

AEL is implemented as `device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso)` — it freezes the current auto values. The EV strip is dimmed and non-interactive while AEL is active.

### Manual controls data flow

```
User drags VerticalDialSlider
  → ISOSlider / ShutterSlider / etc. onChanged callback
  → CameraManager.setISO() / setShutterSpeed() / etc.
      → sessionQueue.async → device.lockForConfiguration → setExposureModeCustom
      → [KVO fires back] → captureSettings.isoValue updated on MainActor
          → SwiftUI re-renders slider label
```

`captureSettings` is the single source of truth for the slider display. KVO observers update it in auto mode so sliders always show the actual camera value, not a stale set point.

### White balance

WB uses `WhiteBalanceTemperatureAndTintValues` with both temperature (Kelvin) and tint (-150 green … +150 magenta). The `TintStrip` in `ManualControlsPanel` appears only when WB is in manual mode. **Crash risk:** each WB gain channel **must** be clamped to `[1.0, device.maxWhiteBalanceGain]` before calling `setWhiteBalanceModeLocked(with:)` — unclamped gains throw `NSInvalidArgumentException`. See `CameraManager.setWhiteBalance(kelvin:tint:)`.

The `WBPreset` enum (in `Models/ShootingMode.swift`) defines 7 presets: Auto (nil Kelvin), Day (5600 K), Cloud (6500 K), Shade (7500 K), Bulb (3200 K), Fluor (4000 K), Flash (5500 K). The preset row in `ManualControlsPanel` shows these as horizontal chips; selecting one calls `CameraManager.setWhiteBalance(kelvin:tint:)` with the preset's Kelvin value.

### Style system

`PhotoStyle.catalog` defines 21 styles across Film / Genre / Mood categories. Each style references a `.cube` filename. If the file isn't found, `LUTLoader.effectiveLUT(for:)` generates LUT data procedurally:

```
LUTLoader.effectiveLUT(for: style)
  ├── tries load(filename:) — parses .cube file from bundle if present
  └── falls back to generateProcedural(name:) using StyleTransforms.params(for:)
        → applies saturation, contrast, exposure, warmth, tint, shadow lift, 3-way color
        → bakes a 17³ LUT (4913 entries) into NSData, cached in NSCache
```

`StyleTransforms.swift` contains per-style parametric definitions. `StylePreviewRenderer` generates thumbnails from the live frame by applying the same `LUTLoader.effectiveLUT` path. Thumbnails are requested in `.onAppear`; if `lastFramePixelBuffer` is nil at that point (camera not started yet), `StylesViewModel.retryPendingThumbnailsOnce()` retries on the first `onPixelBuffer` callback.

### Non-destructive editing

`EditState` (in `Models/EditState.swift`) holds all post-capture adjustments applied non-destructively:

| Property | CIFilter | Range |
|---|---|---|
| `exposure` | CIExposureAdjust inputEV | -2…+2 |
| `contrast` | CIColorControls inputContrast delta | -0.5…+0.5 |
| `shadows` | CIHighlightShadowAdjust inputShadowAmount | -1…+1 |
| `highlights` | CIHighlightShadowAdjust inputHighlightAmount | -1…+1 |
| `saturation` | CIColorControls inputSaturation delta | -1…+1 |
| `vibrance` | CIVibrance inputAmount | -1…+1 |
| `warmth` | CITemperatureAndTint shift | -1…+1 |
| `sharpness` | CISharpenLuminance | 0…1 |
| `vignette` | CIVignette inputIntensity | 0…1 |
| `cropRect` | normalized 0…1 crop rectangle | nil = full |
| `rotationDegrees` | straighten | -45…+45, snaps to 0 on double-tap |

`EditView.swift` presents these as sliders with a before/after toggle. The applied filter chain is re-rendered on export; the original pixel data is never mutated.

### Shooting mode state machine

All mode logic lives in `CameraViewModel.selectMode(index:cropRatioRaw:selfTimerDelay:)`. It runs on `@MainActor` and handles both teardown of the outgoing mode and setup of the incoming one — do not add mode-specific side effects anywhere else.

```
selectMode(newIndex)
  ├── teardown outgoing: stop burst / timelapse / recording; restore crop; disable depth/night
  ├── activeModeIndex = newIndex  (drives UI via ShootingMode.allCases[index])
  └── setup incoming: preset ISO/shutter; enable depth/night API; set crop; enable desqueeze
```

The `modeAdvisoryLine` view in `CameraView` shows per-mode controls (duration slider for long exposure, interval for timelapse, FPS/resolution/codec pickers for video). Add new per-mode controls there.

### Capture flow

```
Shutter tap → CameraView.handleShutter()
  ├── self-timer: CameraViewModel.startTimerCapture → deferred action()
  └── direct: CameraView.performCapture()
        ├── .video     → CameraManager.startRecording() / stopRecording()
        ├── .longExposure → CaptureProcessor.beginLongExposureCapture()
        ├── .burst     → CameraViewModel.startBurst(delegate:)
        ├── .timelapse → CameraViewModel.startTimelapse(delegate:)
        └── default    → CameraManager.capturePhoto(delegate:)
                              ↓ AVFoundation callback
                         CapturePhotoDelegate.photoOutput(_:didFinishProcessingPhoto:)
                              ↓ onProcessed closure (defined in CameraView.makeCaptureDelegate)
                         portrait blur / LUT bake / desqueeze / watermark → saveToPhotoLibrary(data:photo:location:)
```

`CapturePhotoDelegate` is created fresh per capture (`activeDelegates[id] = delegate` keeps it alive until `didFinishCaptureFor` fires the `onCaptureDone` callback that removes it). Never reuse a delegate instance.

**Capture re-entry guard:** `_captureBusy` (a `nonisolated(unsafe)` Bool on `CameraManager`, checked and set atomically on `sessionQueue`) is the true re-entry gate. `isCapturing` is the UI binding only — do not use it as a guard. Call `cameraManager.clearCaptureGuard()` from `onCaptureDone` to reset both atomically; do not write `isCapturing = false` directly.

**Live Photo pairing:** `CapturePhotoDelegate.onLivePhotoMovie` receives the `.mov` URL from `didFinishProcessingLivePhotoToMovieFileAt`. In `CameraView.makeCaptureDelegate`, a `MovieURLBox` (reference-typed wrapper) captures this URL and passes it to `saveToPhotoLibrary(livePhotoMovieURL:)`. The HEIC `.photo` and `.pairedVideo` resources **must be added to the same `PHAssetCreationRequest`** — separate requests produce two unlinked assets that Photos.app never presents as a Live Photo.

### Capture variants

- **AEB (bracketing)**: `capturePhotoBracketed(evStep:delegate:)` uses `AVCapturePhotoBracketSettings` with `AVCaptureAutoExposureBracketedStillImageSettings` at `[-evStep, 0, +evStep]`. Review is only shown for the EV-0 frame (detected via `photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings` + `abs(auto.exposureTargetBias) < 0.01`).
- **RAW+JPEG**: `photo.resolvedSettings.expectedPhotoCount > 1` identifies the RAW callback (JPEG follows); `shouldShowReview = false` for it.
- **Self-timer**: Swift `Task` with 1s sleep loops. `action()` is called inside `await MainActor.run { guard !Task.isCancelled }` to close the race between expiry and cancellation.

### Shooting mode implementation status

| Mode | Status | Notes |
|---|---|---|
| Photo | ✅ Complete | AEB, RAW, RAW+JPEG, watermark, LUT bake |
| Video | ✅ Complete | AVAssetWriter, LUT baked-in, GPS metadata, resolution/codec/FPS switching |
| Long Exposure | ✅ Complete | `CIMaximumCompositing` over N frames in `CaptureProcessor` (capped at 60 frames ≈ 480 MB) |
| Burst | ✅ Complete | 10 frames × 100 ms in `CameraViewModel.startBurst` |
| Self-timer | ✅ Complete | Repeat count + countdown in `CameraViewModel` |
| Timelapse | ✅ Complete | Configurable interval; each frame saved as individual JPEG |
| Anamorphic | ✅ Complete | 2× horizontal desqueeze in `CaptureProcessor`; 2.39:1 crop guide |
| Night | ✅ Complete | Hardware low-light boost + `.quality` QoS; advisory bar shows "HOLD STILL — PROCESSING" during multi-frame capture; yellow spinner overlays shutter button |
| Portrait | ✅ Complete | `isDepthDataDeliveryEnabled` + portrait matte; `CIDepthBlurEffect` (f/2.8) applied in `processCapture` before LUT bake using disparity from `photo.depthData` |

### Feature flags and `@AppStorage` persistence

Runtime visibility for features is controlled via `@AppStorage` keys shared between `CameraView` and `SettingsView` (e.g. `"showGrid"`, `"showHistogram"`, `"showStylePicker"`). After changing a flag that controls a processor-side filter (focus peaking, zebra, false color, LUT), call `cameraViewModel.syncOverlaysToProcessor()`.

`@AppStorage` keys are the persistence layer — there is no separate UserDefaults wrapper. `CameraView` holds the keys and syncs them to `CameraManager`/`CameraViewModel` via `.onChange` modifiers at the bottom of `mainContent`. When adding a new persisted setting, declare it in `CameraView`, mirror it to `SettingsView` by using the same key string, and add an `.onChange` handler to apply it.

Key `@AppStorage` keys:
- Overlays: `showHistogram`, `showGrid`, `showFocusPeaking`, `showZebra`, `showLevelIndicator`, `showFalseColor`, `showWaveform`, `showVectorscope`, `isCleanViewActive`, `histogramMode`
- Capture: `isBracketingEnabled`, `bracketEVStep`, `selfTimerDelay`, `selfTimerRepeat`, `isProRAWEnabled`, `defaultCaptureFormat`, `isWBBracketEnabled`, `wbBracketKStep`, `focusPeakingColor`
- Video: `videoFrameRate`, `videoResolution`
- Other: `cropRatio`, `timelapseInterval`, `longExposureDuration`, `volumeButtonBehavior`, `watermarkText`

### Utility classes

- **`PermissionsManager`** — wraps camera, microphone, photo library, and location authorization in a single `@Observable` class; also owns `CLLocationManager` for GPS tagging.
- **`HapticManager`** — lazy `UIFeedbackGenerator` singletons (`shutter`, `focus`, `selection`, `error`). Call sites just use `HapticManager.shared.shutter.impactOccurred()`.
- **`ExifReader`** — ImageIO-based extraction of ISO, shutter, aperture, WB temperature, GPS coordinates, and capture timestamp from JPEG data.
- **`VolumeHUDSuppressor`** — mutes the system volume pop-up that would otherwise appear during photo capture triggered by the volume button.
- **`HistogramCalculator`** — uses `CIAreaHistogram` to produce a normalized 256-bin RGBL histogram; called every 3rd frame from `CaptureProcessor`.
- **`CapturePresetsManager`** — `@Observable` singleton; saves/loads named `CapturePreset` structs (ISO, shutter, WB, style) to UserDefaults as JSON.
- **`DeviceOrientationTracker`** — `@Observable` singleton; listens to `UIDevice.orientationDidChangeNotification` and exposes `rotationAngle` (in degrees) so UI elements can counter-rotate to stay upright.

### `CIContext.shared`

`Utilities/CIContext+Shared.swift` exposes a single `CIContext` backed by `MTLCreateSystemDefaultDevice()`. Import it anywhere CI rendering is needed — never create a new `CIContext` per frame or per capture. The shared context is thread-safe for concurrent rendering.

### `fxClamped` extension

`Comparable.fxClamped(to:)` is defined in `CameraManager.swift`. It exists because Swift 6 added a `package`-scoped `clamped` to the stdlib, making the common name inaccessible. Use `fxClamped` everywhere in this codebase. Do not define type-specific duplicates (e.g. on `Double` or `CGFloat`) — the generic version covers all numeric types.

### AVCaptureDevice.withLock helper

`AVCaptureDevice.withLock(_:)` (defined in `CameraManager.swift`) wraps `lockForConfiguration()`/`unlockForConfiguration()` with proper error handling. All device configuration in this codebase uses it. Never call `lockForConfiguration()` or `unlockForConfiguration()` directly.

### Logging

Use `Logger` from `OSLog` instead of `print`. The app defines per-category loggers (e.g. `Logger.camera`). Check `CameraView.swift` for the pattern.

### LUT files

`.cube` files belong in `fexer/Resources/LUTs/`. Filenames must match `PhotoStyle.catalog` entries in `Models/PhotoStyle.swift`. `LUTLoader` parses `.cube` format (plain text, B-major order) and pads RGB→RGBA for `CIColorCubeWithColorSpace`. Generated procedural LUT data is cached by `"__proc_<name>_<dim>"` key in the same `NSCache`.

### CIFilter / Metal safety

CIFilter lookups and `MTLCreateSystemDefaultDevice()` use `fatalError` with descriptive messages rather than force-unwraps. These are programmer errors (missing filter name, no Metal support) that should fail catastrophically — never silently.

### Orientation lock

Portrait-only on iPhone via two layers: `AppDelegate.supportedInterfaceOrientationsFor` returns `.portrait`, and `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait` in `project.pbxproj`.

### Privacy keys (project.pbxproj)

All privacy strings live as `INFOPLIST_KEY_NS*` build settings (both Debug and Release configs), not in a separate `Info.plist` file, because `GENERATE_INFOPLIST_FILE = YES`. Edit them in `project.pbxproj`.

### VerticalDialSlider layout contract

Each slider column is pinned to `kColumnWidth = 68pt`. The value label uses `.monospacedDigit()` + `.frame(width: kColumnWidth)` to prevent layout shifts when numbers change length (e.g., "1/8000" vs "30\""). The floating drag capsule is absolutely positioned inside the `ZStack` and uses `.fixedSize()` so it never affects column width.
