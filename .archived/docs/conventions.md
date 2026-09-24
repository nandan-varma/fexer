# Conventions & Utilities

Scope: house patterns and shared utilities every agent must know before writing code. For
the isolation-annotation rules see [docs/architecture.md](architecture.md).

## fxClamped

`Comparable.fxClamped(to:)` is defined in `CameraManager.swift`. It exists because Swift 6
added a `package`-scoped `clamped` to the stdlib, making the common name inaccessible. Use
`fxClamped` everywhere in this codebase. Do **not** define type-specific duplicates (e.g. on
`Double` or `CGFloat`) — the generic version covers all numeric types.

## AVCaptureDevice.withLock

`AVCaptureDevice.withLock(_:)` (defined in `CameraManager.swift`) wraps
`lockForConfiguration()` / `unlockForConfiguration()` with proper error handling. All device
configuration in this codebase uses it. **Never** call `lockForConfiguration()` or
`unlockForConfiguration()` directly.

## Logging

Use `Logger` from `OSLog`, never `print`. Per-category loggers; the pattern is:

```swift
nonisolated static let camera = Logger(subsystem: "com.nandanvarma.fexer", category: "camera")
```

(`CameraView.swift:625`). New subsystems get their own category.

## CIContext.shared

`Utilities/CIContext+Shared.swift` exposes a single `CIContext` backed by
`MTLCreateSystemDefaultDevice()`. Import it anywhere CI rendering is needed — **never create
a new `CIContext` per frame or per capture**. The shared context is thread-safe for
concurrent rendering.

## CIFilter / Metal safety

CIFilter lookups degrade gracefully: `LUTFilter.makeFilter` and the pipeline helpers
`guard` + log via `Logger.camera.error` + skip the step (return nil / pass the image through)
rather than crash on a missing filter. CI Metal kernel compilation
(`CIKernel+Compile.compileMetal`) logs the compiler error and fires `assertionFailure` in
debug builds, returning nil in release. Never force-unwrap a CIFilter lookup — a skipped
filter step is recoverable, a crash in the frame path is not. **Zero
fatalError / force-unwrap / try! / as! is the baseline; keep it that way.**

## Isolation quick rules

(Full model in [docs/architecture.md](architecture.md).)

- sessionQueue-only vars → `@ObservationIgnored nonisolated(unsafe)`.
- Thread-safe NSCache / NSData → `nonisolated(unsafe)` (plain `nonisolated` cascades into
  Sendable violations).
- Pure data structs crossing isolation → `nonisolated struct`, plus an explicit
  `nonisolated init` when the memberwise init is needed off-main.
- **Do NOT extract sessionQueue closure bodies into helpers** — closure bodies are not
  isolation-checked in Swift 5 mode; function bodies are. Extraction produces new warnings.

## Utility classes

- **`PermissionsManager`** — wraps camera, microphone, photo library, and location
  authorization in a single `@Observable` class; also owns `CLLocationManager` for GPS
  tagging.
- **`HapticManager`** — static convenience methods (`light()`, `medium()`, `error()`,
  `selectionChanged()`, `focusLocked()`). Call sites use e.g. `HapticManager.light()`.
  `dialDetent(major:)` fires a tuned `UIImpactFeedbackGenerator(.rigid)` click
  (intensity 1.0 for major detents, 0.55 for minor) for `DialWheelView`'s per-stop feedback —
  the pre-warmed generator is reliable under rapid repeated fire (many detents/sec during a
  fast drag) where a hand-rolled CHHapticEngine per-event is not.
- **`ExifReader`** — ImageIO-based extraction of ISO, shutter, aperture, WB temperature, GPS
  coordinates, and capture timestamp from JPEG data.
- **`VolumeHUDSuppressor`** — mutes the system volume pop-up that would otherwise appear
  during photo capture triggered by the volume button. (`VolumeButtonHandler` in
  Views/SupportingTypes handles the volume-button capture trigger itself.)
- **`HistogramCalculator`** — uses `CIAreaHistogram` to produce a normalized 256-bin RGBL
  histogram; called every 2nd frame from `CaptureProcessor`. Also renders RGBA8 samples for
  waveform/vectorscope (`RGBA8Sample`: `nonisolated struct` with explicit `nonisolated
  init`).
- **`CapturePresetsManager`** — `@Observable` singleton; saves/loads named `CapturePreset`
  structs (ISO, shutter, WB, style) to UserDefaults as JSON.
- **`DeviceOrientationTracker`** — `@Observable` singleton; listens to
  `UIDevice.orientationDidChangeNotification` and exposes `rotationAngle` (in degrees,
  0/90/-90/180). Apply `.rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))`
  to any UI element that should stay upright when the device rotates. `start()` / `stop()`
  are called from `CameraView+Lifecycle.swift`.
- **`CaptureImagePipeline`** — `nonisolated enum` in Utilities/; shared capture-processing
  steps used by `CapturePhotoDelegate` processing (portrait blur, LUT bake, desqueeze,
  watermark).
