# Manual Controls — Exposure, WB, Focus, Lenses

Scope: AE lock, the top-bezel chip strip, `DialWheelView`, white balance presets, and
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

## Top-bezel chip strip (ExposureRailView)

Manual exposure is exposed via a single horizontal row of chips. Rather than computing a pixel
offset into the black letterbox bezel (fragile — `previewImageSize`, and therefore
`CameraView.letterboxBarHeight`, isn't always known/settled by the time SwiftUI first lays this
out, and a fixed guess can drift from the real bezel size), the row is a sibling of
`QuickAccessBar` in the **same** top `VStack` (`CameraView.hudOverlayLayer`), directly below it
with fixed 8pt spacing. Natural VStack flow guarantees it's always adjacent to the bar and never
floating in dead space or over the image, regardless of crop ratio or timing:

- **Fixed, in order**: ISO badge, shutter-speed badge, `appState.leftRailItems`
  (default `[.flash]`), WB (Kelvin) badge, focus (lens position) badge — focus only shown when
  `cameraManager.supportsManualFocus` — then `appState.rightRailItems` (default `[.metering]`).
  The `leftRailItems`/`rightRailItems` user defaults (read/written via
  `AppState.loadRailItems` / `saveRailItems`, not `@AppStorage`) and their Settings UI are
  unchanged; they now just mean "first group" / "second group" within the one row rather than
  two screen halves.

Badges are yellow when in manual mode, dim when auto. Tapping a badge calls
`ExposureRailView.toggle(_:)`, which sets `cameraViewModel.activeRailParam: RailParam?`
(`.iso`, `.shutter`, `.wb`, `.focus`) inside `withAnimation` (opening now reflows layout — see
below — so both open and close need to animate, not just close), triggering `DialWheelView`.

## DialWheelView

Same reasoning as the chip strip: rather than an absolutely-positioned overlay guessing a
bottom padding, `DialWheelView` lives directly in `controlLayer`'s inner `VStack`, right above
`lensSwitcherRow` — the same flow pattern `StylePickerView` already used for its own contextual
panel. Showing it pushes the lens-switcher/shutter row up rather than floating over the image;
tapping a chip animates that reflow via `ExposureRailView.toggle(_:)`.

A 320 pt-wide "big wheel" jog dial with a compact single-row header (label + live value + auto
pointer on the left, an "A"/"M" toggle capsule on the right — single letter, not the word, so
it stays compact when counter-rotated in landscape) above a horizontal `Canvas`-drawn tick
ruler that scrolls beneath a fixed center pointer. The header+toggle share one row rather than
stacking three, keeping the whole widget shallow (~70pt) so it reliably fits inside a typical
bezel instead of spilling onto the image — the trade that governed the shallow/near-flat wheel
curvature choice applies here too: less vertical footprint over more visual flourish.

The wheel's effective radius is far larger than its visible strip: a full 0...1 sweep of the
parameter takes `virtualTrackWidth` (1400 pt) of drag, so a screen-width drag only covers a
fraction of the range — more travel per stop than a linear slider, which is what makes fine
adjustment precise. Dragging follows a content-follows-finger model (drag left reveals higher
values, like advancing a carousel); `HapticManager.dialDetent(major:)` fires once per detent
crossed (`detentIndex(for:)` — real ISO/shutter stop index for those two, a fixed bucket count
for continuous WB/focus), giving a firmer click every 5th (major) detent.

The wheel auto-dismisses after 4 s of inactivity via a `Task`. Tapping the badge again
dismisses it immediately. **The wheel's frame itself never rotates** — it's a fixed object on
the bezel, not a HUD element — but its text content does: the readout stack and the "A"/"M"
toggle each independently apply
`.rotationEffect(.degrees(DeviceOrientationTracker.shared.rotationAngle))` (same pattern as
`RailBadge`) so labels stay legible in landscape while the dial's position/size stay put. The
tick ruler itself is undecorated marks, not text, so it never needs to counter-rotate.

### Manual controls data flow

```text
User drags DialWheelView ruler
  → applyNormalized(_:) sets captureSettings.isAutoISO/Shutter = false, isoValue = stops[idx]
  → cameraManager.setISO(iso)
      → sessionQueue.async → device.setExposureModeCustom(duration: .current, iso: clamped)
      → [KVO fires back] → captureSettings.isoValue updated on MainActor
          → SwiftUI re-renders wheel readout and top-bezel chip
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
