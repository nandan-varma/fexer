# Architecture — Threading & Isolation

Scope: the threading model (the #1 invariant of this codebase), the isolation annotations
that implement it, empirically-verified compiler behavior, session lifecycle, and the class
responsibility map. **Read this before touching ANY capture code, and before extracting or
reorganizing any CameraManager / CaptureProcessor / CaptureProcessor-adjacent logic.**

## The critical invariant: threading model

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set, so every class is `@MainActor` by
default. The two exceptions run on a private GCD queue:

```text
com.fexer.session  (sessionQueue, .userInteractive)
  ├── CameraManager.configureSession / all setXxx() calls
  └── CaptureProcessor.captureOutput(_:didOutput:) — AVFoundation delegate
```

Rules:

1. **AVFoundation calls** (`lockForConfiguration`, `setExposureModeCustom`, …) stay on
   `sessionQueue`.
2. **Any mutation of `@Observable` properties SwiftUI reads crosses back with
   `Task { @MainActor in ... }`.**
3. **Never call `UIView.setNeedsDisplay` from `sessionQueue`** — the MTKView uses continuous
   render mode instead (`isPaused = false`, `enableSetNeedsDisplay = false`).

## Isolation annotations

### sessionQueue-only vars: `@ObservationIgnored nonisolated(unsafe)`

CameraManager's recording-pipeline vars are read and written exclusively on `sessionQueue`.
Every one carries `@ObservationIgnored nonisolated(unsafe)` — without `@ObservationIgnored`,
`@Observable` registers observation access/mutation on the MainActor and produces
actor-isolation violations at runtime. **When adding a new var read/written on sessionQueue,
add both annotations.** The complete current set (CameraManager.swift:76–112):

```text
assetWriter, videoWriterInput, audioWriterInput, pixelBufferAdaptor,
isWaitingToRecord, pendingRecordingLocation, pendingRecordingStyleName,
isFinishingRecording, prebuiltWriterEntry, isPrebuiltBuilding,
pendingRecordOnPrebuiltComplete, preHDRFormat, _captureBusy,
pendingBracketCompletions, audioSampleCount, iso8601Formatter
```

Notes:

- `iso8601Formatter` is a `nonisolated(unsafe) let` (not `lazy`) — `ISO8601DateFormatter` is
  thread-safe, and a lazy var would race its MainActor-isolated init from sessionQueue.
- `audioSampleCount` increments with `&+=` (overflow-safe); the audio delegate posts a
  MainActor Task only when `audioSampleCount % 5 == 0` (~10 fps VU-meter updates).
- `WriterComponents` = `{ writer, videoInput, audioInput, adaptor }`. Prebuilt writers are
  built on `writerSetupQueue` (a separate queue) — code there must not touch the
  nonisolated(unsafe) instance vars.

### `nonisolated(unsafe)` for thread-safe value holders

NSCache / NSData that are internally thread-safe use plain `nonisolated(unsafe)` — matches
`StylePreviewRenderer.cache`, `LUTLoader.cache`, `LUTEntry.data`. Plain `nonisolated` on
these cascades into Sendable violations ("'nonisolated' can not be applied to variable with
non-'Sendable' type").

### `nonisolated` data structs

Pure data structs that must be constructible/readable off the MainActor are marked
`nonisolated struct` (`HistogramData`, `StyleParams`, `RGBA8Sample`, `LongExpConfig`). Two
gotchas:

- The **implicit memberwise init stays MainActor-isolated even on a nonisolated struct** —
  types that need constructing off-main (e.g. `RGBA8Sample`) get an explicit
  `nonisolated init`.
- `@Observable` classes are different: their vars need `@ObservationIgnored
  nonisolated(unsafe)`, not struct annotations.

### Classes with explicit `nonisolated` APIs (called from non-MainActor contexts)

- `StylePreviewRenderer` — all public methods (uses `OSAllocatedUnfairLock` internally).
- `StylesViewModel.onFrameAvailable`.
- `LUTLoader` — all loading/generation (thread-safe NSCache + immutable entries).
- `StyleTransforms` — `static params(for:)` / `apply(...)`.
- `CaptureImagePipeline` — `nonisolated enum` (shared capture-processing steps).

## ⚠ Empirically verified: sessionQueue closures are NOT isolation-checked

Swift 5.0 mode (SWIFT_VERSION=5.0, no SWIFT_STRICT_CONCURRENCY) uses minimal isolation
checking. Verified by stash-test: the original inline `sessionQueue.async` closures that
mutate MainActor state compile with **zero warnings**, but extracted helper functions do not:

- Helper declared `nonisolated` → warnings INSIDE the helper body (MainActor member access).
- Helper declared `@MainActor` → warnings at EVERY call site ("call to main actor-isolated
  instance method … in a synchronous nonisolated context").
- Original inline code → zero warnings.

**Consequence: do not extract sessionQueue closure bodies into named functions.** The
camera-swap and writer-install helper extractions were attempted and reverted for exactly
this reason. The resulting jscpd duplicate blocks in CameraManager.swift and
CameraManager+VideoRecording.swift are intentionally left inline. If you must share code
across two sessionQueue closures, share a closure variable or keep it inline.

## Session lifecycle

- `startSession()` registers `sessionInterruptionObserver` on
  `AVCaptureSession.wasInterruptedNotification`. A phone call, Siri, or system audio event
  fires the handler, which calls `stopRecording()` (dispatches to sessionQueue) if
  `isRecording || isWaitingToRecord`. `sessionInterruptionEndedObserver` restarts the session
  and re-applies rotation. Both observers are torn down in `stopSession()`.
- Video rotation: `configureVideoRotation()` sets `connection.videoRotationAngle = 90` right
  after `session.commitConfiguration()` (portrait-upright frames from landscape input). Must
  also run after `flipCamera()`. Deferred ~150 ms after `startRunning()` to let AVFoundation
  stabilize (prevents Fig error -12710).

## Key classes

| Class | Thread | Owns |
| --- | --- | --- |
| `CameraManager` | `@Observable`; reads on MainActor, mutations dispatched to sessionQueue | `AVCaptureSession`, `AVCapturePhotoOutput`, `AVCaptureVideoDataOutput`, KVO observations, `previewImageSize`, `backLenses`, `activeLensOpticalFactor`, `discoveredCameras`, `recordingError`, the sessionQueue-only recording vars above |
| `CaptureProcessor` | sessionQueue | Per-frame CI filter chain, monitoring (histogram/waveform/vectorscope every 2nd frame), `OSAllocatedUnfairLock`-protected `latestImage`, `onPixelBuffer` (first frame + every 60th) |
| `CameraViewModel` | `@MainActor` | UI gesture state (`activeRailParam`, overlay toggles, histogram data), self-timer, AE-lock toggle, burst/timelapse state, mode state machine |
| `StylesManager` | `@Observable` | LUT catalog, active style, `SceneClassifier`; `activeLUTFilter()` falls back to procedural generation |
| `StylesViewModel` | `@Observable` | Thumbnail cache; wires `CaptureProcessor.onPixelBuffer` → `StylePreviewRenderer` |
| `GalleryViewModel` | `@Observable` | Photo Library fetch, PHImageManager, PHPhotoLibraryChangeObserver |
| `AppState` | `@Observable` singleton | Screen routing (`currentScreen`), quick-access bar order |

## Orientation lock

Portrait-only on iPhone via two layers: `AppDelegate.supportedInterfaceOrientationsFor`
returns `.portrait`, and `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone =
UIInterfaceOrientationPortrait` in `project.pbxproj`. Individual UI elements counter-rotate
using `DeviceOrientationTracker` (see [docs/ui-architecture.md](ui-architecture.md)).
