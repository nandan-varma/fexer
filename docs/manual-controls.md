# Manual Controls — Exposure, WB, Focus, Lenses

Scope: AE lock, the side-rail badge system, `ParameterStripView`, white balance presets, and
lens switching. Read with [docs/architecture.md](architecture.md) (all device configuration
runs on sessionQueue).

## AE Lock

`captureSettings.isAELocked` is the **single source of truth** — set/cleared by
`lockAutoExposure()` / `unlockAutoExposure()` / `setAutoExposure()` on `sessionQueue`, then
posted to the MainActor. `CameraViewModel.isAELocked` is a computed property reading through
to `captureSettings`; it has no stored state. This prevents the AEL badge and slider state
from drifting out of sync with hardware.

AEL is implemented as
`device.setExposureModeCustom(duration: device.exposureDuration, iso: device.iso)` — it
freezes the current auto values. Long-press on the shutter button toggles AEL.

## Side-rail system (ExposureRailView)

Manual exposure is exposed via two persistent side-rail columns overlaid on the viewfinder:

- **Left rail**: ISO badge + shutter-speed badge.
- **Right rail**: WB (Kelvin) badge + focus (lens position) badge — focus only shown when
  `cameraManager.supportsManualFocus`.

Badges are yellow when in manual mode, dim when auto. Tapping a badge sets
`cameraViewModel.activeRailParam: RailParam?` (`.iso`, `.shutter`, `.wb`, `.focus`), which
triggers `ParameterStripView` to appear above the bottom controls.

## ParameterStripView

A 280 × ~90 pt horizontal strip containing:

1. Parameter name + live value label + auto/manual toggle button.
2. A draggable scrub track — snaps to `CaptureSettings.isoStops` / `CaptureSettings.shutterStops`
   for discrete params, continuous for WB and focus.
3. Representative step labels.

The strip auto-dismisses after 4 s of inactivity via a `Task`. Tapping the badge again
dismisses it immediately. Both `ExposureRailView` and `ParameterStripView` apply
`.rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))` to counter-rotate
when the device is held in landscape.

### Manual controls data flow

```text
User drags ParameterStripView track
  → applyNormalized(_:) sets captureSettings.isAutoISO/Shutter = false, isoValue = stops[idx]
  → cameraManager.setISO(iso)
      → sessionQueue.async → device.setExposureModeCustom(duration: .current, iso: clamped)
      → [KVO fires back] → captureSettings.isoValue updated on MainActor
          → SwiftUI re-renders strip label and rail badge
```

`captureSettings` is the source of truth for **all** displayed values. KVO observers update
it in auto mode so badges always show the actual camera value, not a stale set point.

### Auto/manual flag rules

- ISO and shutter share the exposure mode — switching either to manual calls `setISO` /
  `setShutterSpeed` (which internally call `setExposureModeCustom`); switching back calls
  `setAutoExposure()` and sets both flags to true.
- WB and focus have independent auto flags; restore via `setAutoWhiteBalance()` /
  `setAutoFocus()`.
- Directly toggling `captureSettings.isAutoXxx` does NOT configure the device; always pair it
  with the appropriate `cameraManager.setXxx()` call.

## White balance

WB uses `WhiteBalanceTemperatureAndTintValues` with both temperature (Kelvin) and tint
(-150 green … +150 magenta). **Crash risk:** each WB gain channel **must** be clamped to
`[1.0, device.maxWhiteBalanceGain]` before calling `setWhiteBalanceModeLocked(with:)` —
unclamped gains throw `NSInvalidArgumentException`. See
`CameraManager.setWhiteBalance(kelvin:tint:)`.

`WBPreset` (Models/ShootingMode.swift) — 7 presets:

| Preset | Kelvin | Tint |
| --- | --- | --- |
| Auto | nil | 0 |
| Day | 5600 | 0 |
| Cloud | 6500 | 5 |
| Shade | 7500 | 10 |
| Bulb (tungsten) | 3200 | -8 |
| Fluor (fluorescent) | 4000 | 20 |
| Flash | 5500 | -3 |

## Lens switching

- **The session always uses a physical camera** — never a virtual multi-lens device
  (`builtInTripleCamera`, `builtInDualCamera`, etc.). Virtual devices return `false` for
  `isLockingFocusWithCustomLensPositionSupported` and `isExposureModeSupported(.custom)`,
  which silently blocks all manual controls.
- `buildBackLensMap()` queries the virtual device **for discovery only** (never adding it to
  the session), extracts the constituent physical cameras and their optical factors relative
  to wide-angle = 1×, and stores the result in `backLenses: [LensOption]`. Called once in
  `configureSession()`.
- `configureSession()` starts on `AVCaptureDevice.default(.builtInWideAngleCamera, …,
  position: .back)`. `switchToCamera(_ lens: LensOption)` swaps the video device input to a
  different physical camera, updates `activeLensOpticalFactor`, and resets digital zoom to 1×.
- `CameraView+LensSwitcher.swift` drives the lens-switcher row from `backLenses`. The active
  button is identified by `lens.device == cameraManager.currentDevice`. The live optical zoom
  label = `currentZoomFactor × activeLensOpticalFactor`. The ZoomDial (long-press) controls
  digital zoom within the current physical lens.
- `availableZoomFactors` (used by optical zoom lock to snap the pinch gesture to glass-only
  stops) returns `[minAvailableVideoZoomFactor, 1.0]` when min < 1.0 (ultra-wide), or `[1.0]`
  otherwise. It does **not** use `virtualDeviceSwitchOverVideoZoomFactors` — that property
  returns `[]` on physical cameras, which fexer always uses.
- `flipCamera()` restores the back camera to the wide-angle
  (`backLenses.first { $0.opticalFactor == 1.0 }?.device`); the front camera uses
  `bestCamera(for: .front)` (TrueDepth → wide-angle, both physical). Note: `flipCamera()`
  removes ALL session inputs (+ re-adds the microphone) — it does not share the video-only
  swap pattern of `switchToCamera`.
