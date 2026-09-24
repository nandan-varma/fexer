# Camera Pipeline — Frames, Filters, Rendering

Scope: per-frame processing from `AVCaptureVideoDataOutput` to the MTKView, the filter chain
and its order, lock discipline, rotation/coordinate mapping, and rendering/letterbox rules.
Pair with [docs/architecture.md](architecture.md) (threading) and [docs/conventions.md](conventions.md)
(`CIContext.shared`).

## Frame path

```text
AVCaptureVideoDataOutput
  → CaptureProcessor.captureOutput (sessionQueue)
      ├── [1] FalseColorFilter (CIColorKernel) — if enabled; skips LUT + zebra
      ├── [2] LUTFilter (CIColorCubeWithColorSpace) — skipped when false color active
      ├── [3] FocusPeakingFilter (CIColorKernel) — optional, always on top
      ├── [4] ZebraFilter (CIColorKernel) — optional, skipped when false color active
      └── CIImage stored in imageLock (OSAllocatedUnfairLock)
            ↓
CameraPreview.Coordinator.draw(in: MTKView) — continuous 60 fps
```

**Order rationale:** false color must see the ungraded signal (diagnostic tool), LUT is the
creative grade, peaking and zebra are analysis tools drawn on top of whatever the user is
monitoring.

## Lock discipline (CaptureProcessor)

All mutable state crossing the sessionQueue/MainActor boundary uses `OSAllocatedUnfairLock`:
`imageLock`, `lutFilterLock`, `peakingColorLock`, `flagsLock`, `zebraTimeLock`,
`rotationReadyLock`, `longExpActiveLock`, `longExpConfigLock`.

- `longExpConfigLock` protects `longExpDuration` and `onLongExposureComplete`.
  `beginLongExposureCapture` runs on the MainActor but `captureOutput` reads them on
  sessionQueue. Access both exclusively through their computed-property wrappers — never read
  the lock's raw state directly.
- The single shared `CIContext` (Utilities/CIContext+Shared.swift, backed by
  `MTLCreateSystemDefaultDevice()`) is never recreated — per-frame context creation is
  expensive. It is thread-safe for concurrent rendering.

## Frame cadence facts

- `onPixelBuffer` fires on the first frame, then every 60th (~1/s at 60 fps) — the thumbnail
  feed for `StylePreviewRenderer`.
- Histogram / waveform / vectorscope: computed on `histogramQueue` **every 2nd frame** when
  any of the three overlay flags is set (`frameCount % 2 == 0`). (Older docs claimed "every
  3rd frame" — that is stale; 2nd is correct.)
- Long exposure: `CIMaximumCompositing` over N frames, sampling every 4th frame
  (`kLongExpFrameSkip = 4` → ~15 fps from 60 fps input), capped at `kLongExpMaxFrames = 60`
  (≈ 480 MB peak).

## Rotation & coordinate mapping

Video frames arrive in landscape orientation. `configureVideoRotation()` sets
`connection.videoRotationAngle = 90` (see [docs/architecture.md](architecture.md) for
timing). The 90° rotation means AVFoundation's coordinate space has swapped axes relative to
the portrait screen:

```swift
// In CameraPreview.Coordinator.handleTap (screen point → normalized device coords):
normalized = CGPoint(x: point.y / size.height, y: 1 - point.x / size.width)

// Inverse (normalized → screen point, for the focus square in ViewfinderView):
screenPoint = CGPoint(x: (1 - normalized.y) * geo.size.width,
                      y: normalized.x * geo.size.height)
```

Swapping x/y when recovering the screen position is intentional — do not "simplify" it.

## Rendering modes (CameraPreview)

`CameraPreview` is a `UIViewRepresentable` wrapping `MTKView`; the `Coordinator` implements
`MTKViewDelegate`. Two render modes depending on `cropRatio`:

- **`.full`**: aspect-fit (`scale = min(scaleX, scaleY)`), composited over black background —
  produces black bars INSIDE the MTKView.
- **Non-full**: aspect-fill (`scale = max(scaleX, scaleY)`); the `bounds:` parameter
  center-crops. SwiftUI letterbox bars are decorative crop guides only — the MTKView still
  renders full-frame.

```swift
ciContext.render(scaled, to: drawable.texture, commandBuffer: commandBuffer,
                 bounds: cropRect,   // ← offset into scaled image, NOT CGRect.zero
                 colorSpace: sRGB)
```

## Letterbox / overlay positioning

All viewfinder overlays (grid, histogram, level indicator, timer countdown) must be
constrained to the actual preview area, not the full screen. `CameraView.letterboxBarHeight`
computes the inset:

- **Crop modes**: `barH = (screen.height - screen.width/aspect) / 2`.
- **Full mode**: uses `cameraManager.previewImageSize` (set on the first frame via
  `CaptureProcessor.onPreviewSizeKnown`) to compute the aspect-fit inset using the image
  aspect ratio — avoids pixel/point unit mismatch.

`CameraPreview.Coordinator.previewBarHeight(viewSize:)` mirrors this logic at the UIKit level
so tap-to-focus and brightness-swipe gestures don't fire inside the black bars.
