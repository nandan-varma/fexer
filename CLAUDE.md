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

### Camera pipeline (frame path)

```
AVCaptureVideoDataOutput
  → CaptureProcessor.captureOutput (sessionQueue)
      ├── LUTFilter (CIColorCubeWithColorSpace) — applied if style active
      ├── FocusPeakingFilter (GLSL CIColorKernel) — optional
      ├── ZebraFilter (GLSL CIColorKernel) — optional
      └── CIImage stored in latestImage (NSLock)
            ↓
CameraPreview.Coordinator.draw(in: MTKView) — continuous 60fps
  ciContext.render(scaledImage, to: drawable.texture, bounds: centerCropRect)
```

`CaptureProcessor.lutFilter` is read from `sessionQueue` but written from `MainActor` — guarded by `lutFilterLock` (NSLock). The single shared `CIContext(mtlDevice:)` is never recreated; recreating it per-frame is expensive.

Video frames arrive in landscape orientation. `configureVideoRotation()` sets `connection.videoRotationAngle = 90` immediately after `session.commitConfiguration()` to deliver portrait-upright frames. This must also be called after `flipCamera()`.

### Key classes

| Class | Thread | Owns |
|---|---|---|
| `CameraManager` | `@Observable`, properties read on MainActor, mutations dispatched to `sessionQueue` | `AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`, KVO observations |
| `CaptureProcessor` | `sessionQueue` | Per-frame CI pipeline, histogram computation (every 3rd frame), `NSLock`-protected `latestImage` |
| `CameraViewModel` | `@MainActor` | UI gesture state, overlay toggles, histogram data (receives via `onHistogramUpdate` callback → `Task { @MainActor }`) |
| `StylesManager` | `@Observable` | LUT catalog, active style, `SceneClassifier` |
| `AppState` | `@Observable`, singleton | Screen routing (`currentScreen`), quick-access bar order |

### Rendering

`CameraPreview` is a `UIViewRepresentable` wrapping `MTKView`. The `Coordinator` implements `MTKViewDelegate` and does center-crop aspect-fill:

```swift
// Aspect-fill then center-crop using the `bounds:` parameter (avoids .cropped())
ciContext.render(scaledImage, to: drawable.texture, commandBuffer: commandBuffer,
                 bounds: cropRect,   // ← offset into scaled image, NOT CGRect.zero
                 colorSpace: sRGB)
```

### Feature flags

`App/FeatureFlags.swift` — static booleans. Flip to `true` to enable a feature, `false` to ship without it. Currently enabled: manual controls, histogram, camera flip, lens switch, tap-to-focus, pinch-to-zoom, focus slider. Disabled: shooting modes, style picker, grid, focus peaking, zebra, level indicator, gallery, settings.

After changing a flag, call `cameraViewModel.syncOverlaysToProcessor()` if the flag controls a processor-side filter (focus peaking, zebra, LUT).

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

`EVStrip` reads `cameraManager.captureSettings.exposureCompensation` directly (no local `@State`) — this is kept consistent by `setExposureCompensation` writing back to `captureSettings` on `MainActor` after applying to the device.

### White balance clamping — crash risk

When calling `setWhiteBalanceModeLocked(with:)`, each gain channel **must** be clamped to `[1.0, device.maxWhiteBalanceGain]`. Unclamped gains throw `NSInvalidArgumentException` at runtime. See `CameraManager.setWhiteBalance(kelvin:)`.

### `fxClamped` extension

`Comparable.fxClamped(to:)` is defined on `CameraManager.swift`. It exists because Swift 6 added a `package`-scoped `clamped` to the stdlib, making the common name inaccessible. Use `fxClamped` everywhere in this codebase.

### LUT files

`.cube` files belong in `fexer/Resources/LUTs/`. Filenames must match `PhotoStyle.catalog` entries in `Models/PhotoStyle.swift`. `LUTLoader` parses `.cube` format (plain text, B-major order) and pads RGB→RGBA for `CIColorCubeWithColorSpace`. GPU texture is cached by `NSData` pointer identity — never recreate the `NSData` object per frame.

### Orientation lock

Portrait-only on iPhone via two layers: `AppDelegate.supportedInterfaceOrientationsFor` returns `.portrait`, and `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = UIInterfaceOrientationPortrait` in `project.pbxproj`.

### Privacy keys (project.pbxproj)

All privacy strings live as `INFOPLIST_KEY_NS*` build settings (both Debug and Release configs), not in a separate `Info.plist` file, because `GENERATE_INFOPLIST_FILE = YES`. Edit them in `project.pbxproj`.

### VerticalDialSlider layout contract

Each slider column is pinned to `kColumnWidth = 68pt`. The value label uses `.monospacedDigit()` + `.frame(width: kColumnWidth)` to prevent layout shifts when numbers change length (e.g., "1/8000" vs "30\""). The floating drag capsule is absolutely positioned inside the `ZStack` and uses `.fixedSize()` so it never affects column width.
