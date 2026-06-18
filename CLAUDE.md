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
```

**Camera does not work in Simulator.** All meaningful testing requires a physical iOS device. There are no unit tests in this project yet.

SourceKit shows many false-positive errors (UIKit types "unavailable in macOS", cross-file references "not found") because it indexes against the macOS SDK. Ignore them; `xcodebuild` against the iOS SDK is the truth.

## Architecture

### Threading model — the critical invariant

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set, so every class is `@MainActor` by default. The two exceptions are the camera pipeline classes, which run on a private GCD queue:

```
com.fexer.session  (sessionQueue, .userInteractive)
  └── CameraManager.configureSession / all setXxx() calls
  └── CaptureProcessor.captureOutput(_:didOutput:) — AVFoundation delegate
```

**Rule:** AVFoundation calls (`lockForConfiguration`, `setExposureModeCustom`, etc.) must stay on `sessionQueue`. Any mutation of `@Observable` properties that SwiftUI reads must cross back with `Task { @MainActor in ... }`. Never call `UIView.setNeedsDisplay` from `sessionQueue` — use the MTKView's continuous render mode instead (`isPaused = false`, `enableSetNeedsDisplay = false`).

Classes with explicit `nonisolated` methods that may be called from non-MainActor contexts: `StylePreviewRenderer` (all public methods), `StylesViewModel.onFrameAvailable`. These use `NSLock` for internal thread safety rather than actor isolation.

### Camera pipeline (frame path)

```
AVCaptureVideoDataOutput
  → CaptureProcessor.captureOutput (sessionQueue)
      ├── [1] FalseColorFilter (CIColorKernel) — if enabled; skips LUT + zebra
      ├── [2] LUTFilter (CIColorCubeWithColorSpace) — skipped when false color active
      ├── [3] FocusPeakingFilter (CIColorKernel) — optional, always on top
      ├── [4] ZebraFilter (CIColorKernel) — optional, skipped when false color active
      └── CIImage stored in latestImage (NSLock)
            ↓
CameraPreview.Coordinator.draw(in: MTKView) — continuous 60fps
```

**Pipeline order rationale:** False color must see the ungraded signal (diagnostic tool), LUT is the creative grade, peaking and zebra are analysis tools drawn on top of whatever the user is monitoring.

`CaptureProcessor.lutFilter` is read from `sessionQueue` but written from `MainActor` — guarded by `lutFilterLock` (NSLock). The single shared `CIContext(mtlDevice:)` is never recreated; recreating it per-frame is expensive.

Video frames arrive in landscape orientation. `configureVideoRotation()` sets `connection.videoRotationAngle = 90` immediately after `session.commitConfiguration()` to deliver portrait-upright frames. This must also be called after `flipCamera()`.

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

### Key classes

| Class | Thread | Owns |
|---|---|---|
| `CameraManager` | `@Observable`, properties read on MainActor, mutations dispatched to `sessionQueue` | `AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`, KVO observations, `previewImageSize` |
| `CaptureProcessor` | `sessionQueue` | Per-frame CI filter chain, histogram computation (every 3rd frame), `NSLock`-protected `latestImage`, `onPixelBuffer` callback (fires every 60th frame) |
| `CameraViewModel` | `@MainActor` | UI gesture state, overlay toggles, histogram data, self-timer, AE lock toggle |
| `StylesManager` | `@Observable` | LUT catalog, active style, `SceneClassifier`; `activeLUTFilter()` falls back to procedural generation |
| `StylesViewModel` | `@Observable` | Thumbnail cache, wires `CaptureProcessor.onPixelBuffer` → `StylePreviewRenderer` |
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

### Capture variants

- **AEB (bracketing)**: `capturePhotoBracketed(evStep:delegate:)` uses `AVCapturePhotoBracketSettings` with `AVCaptureAutoExposureBracketedStillImageSettings` at `[-evStep, 0, +evStep]`. Review is only shown for the EV-0 frame (detected via `photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings` + `abs(auto.exposureTargetBias) < 0.01`).
- **RAW+JPEG**: `photo.resolvedSettings.expectedPhotoCount > 1` identifies the RAW callback (JPEG follows); `shouldShowReview = false` for it.
- **Self-timer**: Swift `Task` with 1s sleep loops. `action()` is called inside `await MainActor.run { guard !Task.isCancelled }` to close the race between expiry and cancellation.

### Feature flags

`App/FeatureFlags.swift` — all flags are currently `true`. Runtime visibility is controlled per-feature via `@AppStorage` keys shared between `CameraView` and `SettingsView` (e.g. `"showGrid"`, `"showHistogram"`, `"showStylePicker"`). After changing a flag that controls a processor-side filter (focus peaking, zebra, false color, LUT), call `cameraViewModel.syncOverlaysToProcessor()`.

### `fxClamped` extension

`Comparable.fxClamped(to:)` is defined in `CameraManager.swift`. It exists because Swift 6 added a `package`-scoped `clamped` to the stdlib, making the common name inaccessible. Use `fxClamped` everywhere in this codebase.

### LUT files

`.cube` files belong in `fexer/Resources/LUTs/`. Filenames must match `PhotoStyle.catalog` entries in `Models/PhotoStyle.swift`. `LUTLoader` parses `.cube` format (plain text, B-major order) and pads RGB→RGBA for `CIColorCubeWithColorSpace`. Generated procedural LUT data is cached by `"__proc_<name>_<dim>"` key in the same `NSCache`.

### Orientation lock

Portrait-only on iPhone via two layers: `AppDelegate.supportedInterfaceOrientationsFor` returns `.portrait`, and `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait` in `project.pbxproj`.

### Privacy keys (project.pbxproj)

All privacy strings live as `INFOPLIST_KEY_NS*` build settings (both Debug and Release configs), not in a separate `Info.plist` file, because `GENERATE_INFOPLIST_FILE = YES`. Edit them in `project.pbxproj`.

### VerticalDialSlider layout contract

Each slider column is pinned to `kColumnWidth = 68pt`. The value label uses `.monospacedDigit()` + `.frame(width: kColumnWidth)` to prevent layout shifts when numbers change length (e.g., "1/8000" vs "30\""). The floating drag capsule is absolutely positioned inside the `ZStack` and uses `.fixedSize()` so it never affects column width.
