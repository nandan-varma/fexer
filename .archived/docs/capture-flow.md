# Capture Flow — Shutter, Photo/Video, Modes

Scope: what happens on shutter tap, delegate lifecycle, capture variants, video recording
invariants, and the shooting-mode state machine. Read with [docs/architecture.md](architecture.md).

## Shutter flow

```text
Shutter tap → CameraView.handleShutter()
  ├── self-timer: CameraViewModel.startTimerCapture → deferred action()
  └── direct: CameraView.performCapture()
        ├── .video        → CameraManager.startRecording() / stopRecording()
        ├── .longExposure → CaptureProcessor.beginLongExposureCapture()
        ├── .burst        → CameraViewModel.startBurst(delegate:)
        ├── .timelapse    → CameraViewModel.startTimelapse(delegate:)
        └── default       → CameraManager.capturePhoto(delegate:)
                                ↓ AVFoundation callback
                           CapturePhotoDelegate.photoOutput(_:didFinishProcessingPhoto:)
                                ↓ onProcessed closure (defined in CameraView.makeCaptureDelegate)
                           portrait blur / LUT bake / desqueeze / watermark
                                → saveToPhotoLibrary(data:photo:location:)
```

## Delegate lifecycle

`CapturePhotoDelegate` is created fresh per capture. `activeDelegates[id] = delegate` keeps
it alive until `didFinishCaptureFor` fires the `onCaptureDone` callback that removes it.
**Never reuse a delegate instance.**

## Re-entry guard

`_captureBusy` (a `nonisolated(unsafe)` Bool on `CameraManager`, checked and set atomically
on `sessionQueue`) is the true re-entry gate. `isCapturing` is the UI binding only — never
use it as a guard. Call `cameraManager.clearCaptureGuard()` from `onCaptureDone` to reset
both atomically; do not write `isCapturing = false` directly.

## Live Photo pairing

`CapturePhotoDelegate.onLivePhotoMovie` receives the `.mov` URL from
`didFinishProcessingLivePhotoToMovieFileAt`. In `CameraView.makeCaptureDelegate`, a
`MovieURLBox` (reference-typed wrapper) captures this URL and passes it to
`saveToPhotoLibrary(livePhotoMovieURL:)`. The HEIC `.photo` and `.pairedVideo` resources
**must be added to the same `PHAssetCreationRequest`** — separate requests produce two
unlinked assets that Photos.app never presents as a Live Photo.

## Capture variants

- **AEB (bracketing)**: `capturePhotoBracketed(evStep:delegate:)` uses
  `AVCapturePhotoBracketSettings` with `AVCaptureAutoExposureBracketedStillImageSettings` at
  `[-evStep, 0, +evStep]`. Review is only shown for the EV-0 frame (detected via
  `photo.bracketSettings as? AVCaptureAutoExposureBracketedStillImageSettings` +
  `abs(auto.exposureTargetBias) < 0.01`).
- **RAW+JPEG**: `photo.resolvedSettings.expectedPhotoCount > 1` identifies the RAW callback
  (JPEG follows); `shouldShowReview = false` for it.
- **Self-timer**: Swift `Task` with 1s sleep loops. `action()` is called inside
  `await MainActor.run { guard !Task.isCancelled }` to close the race between expiry and
  cancellation.

## Video recording invariants

- `isFinishingRecording` (sessionQueue-only) is set `true` the moment `stopRecording` clears
  the writer vars, and cleared inside `finishWriting`'s completion via `sessionQueue.async`.
  The `startRecording` guard checks
  `guard !isWaitingToRecord && !isFinishingRecording && assetWriter == nil` — this closes the
  TOCTOU window where a new writer starts while the old one's `finishWriting` callback is
  still running.
- `recordingError: Error?` (MainActor, `@Observable`) is set from `finishWriting`'s system
  thread via `Task { @MainActor in }` when `writer.status != .completed`; cleared at the
  start of each `startRecording`. `CameraView.hudOverlayLayer` shows a red toast while it is
  non-nil.
- `audioSampleCount` (sessionQueue-only) increments with `&+=`; the audio delegate posts a
  MainActor Task only when `audioSampleCount % 5 == 0`, throttling VU-meter updates to
  ~10 fps.

## Shooting-mode state machine

All mode logic lives in `CameraViewModel.selectMode(index:cropRatioRaw:selfTimerDelay:)`. It
runs on `@MainActor` and handles both teardown of the outgoing mode and setup of the incoming
one — **do not add mode-specific side effects anywhere else.**

```text
selectMode(newIndex)
  ├── teardown outgoing: stop burst / timelapse / recording; restore crop; disable depth/night
  ├── activeModeIndex = newIndex  (drives UI via ShootingMode.allCases[index])
  └── setup incoming: preset ISO/shutter; enable depth/night API; set crop; enable desqueeze
```

- Per-mode controls live in `modeAdvisoryLine` (`CameraView+ShootingModes.swift`): duration
  slider for long exposure, interval for timelapse, FPS/resolution/codec pickers for video.
  Add new per-mode controls there.
- Horizontal swipe on the viewfinder cycles `activeModeIndex`. The panel-expansion gesture
  has been removed; the swipe-up gesture now only handles horizontal mode cycling.

## Mode implementation status

| Mode | Status | Notes |
| --- | --- | --- |
| Photo | ✅ Complete | AEB, RAW, RAW+JPEG, watermark, LUT bake |
| Video | ✅ Complete | AVAssetWriter, LUT baked in, GPS metadata, resolution/codec/FPS switching |
| Long Exposure | ✅ Complete | `CIMaximumCompositing` over ≤60 frames in `CaptureProcessor` (sampled every 4th, ≈480 MB cap) |
| Burst | ✅ Complete | 10 frames × 100 ms in `CameraViewModel.startBurst` |
| Self-timer | ✅ Complete | Repeat count + countdown in `CameraViewModel` |
| Timelapse | ✅ Complete | Configurable interval; each frame saved as individual JPEG |
| Anamorphic | ✅ Complete | 2× horizontal desqueeze in `CaptureProcessor`; 2.39:1 crop guide |
| Night | ✅ Complete | Hardware low-light boost + `.quality` QoS; "HOLD STILL — PROCESSING" advisory during multi-frame capture; yellow spinner overlays the shutter |
| Portrait | ✅ Complete | `isDepthDataDeliveryEnabled` + portrait matte; `CIDepthBlurEffect` (f/2.8) applied in `processCapture` BEFORE the LUT bake, using disparity from `photo.depthData` |

**All non-Photo modes are gated behind `FeatureFlags.shootingModesEnabled = false`**
(`Models/ShootingMode.swift`) — the mode picker, horizontal-swipe cycling, and home-screen
Quick Actions all check the flag, so only Photo ships today. Flip it to `true` when the modes
are ready to ship; the state machine above is then reachable and tested on device.
