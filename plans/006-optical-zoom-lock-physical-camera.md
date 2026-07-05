# Plan 006: Fix `availableZoomFactors` for physical camera devices

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager+VideoConfiguration.swift`
> On mismatch treat as STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

`availableZoomFactors` is used by the optical zoom lock feature to snap the pinch gesture to glass-only optical stops (no digital crop). The current implementation:

```swift
var availableZoomFactors: [CGFloat] {
    guard let device = currentDevice else { return [] }
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
    return [device.minAvailableVideoZoomFactor] + switchOvers
}
```

`virtualDeviceSwitchOverVideoZoomFactors` is an `AVCaptureDevice` property that **only returns non-empty values for virtual multi-lens devices** (builtInDualCamera, builtInTripleCamera, etc.). Because fexer's session always uses a **physical camera** (this is an explicit design decision documented in CLAUDE.md to support manual controls), `currentDevice.virtualDeviceSwitchOverVideoZoomFactors` always returns `[]`.

Result: `availableZoomFactors` returns `[device.minAvailableVideoZoomFactor]` — just one zoom factor. The optical zoom lock's snap logic in `setZoom`:

```swift
if captureSettings.isOpticalZoomLocked {
    let stops = availableZoomFactors
    target = stops.min(by: { abs($0 - factor) < abs($1 - factor) }) ?? factor
}
```

…always snaps to `minAvailableVideoZoomFactor` (1.0× for wide, 0.5× for ultra-wide). The feature is silently broken on multi-lens devices — it should snap to the optical stops from `backLenses`, not from `virtualDeviceSwitchOverVideoZoomFactors`.

## Current state

File: `fexer/Camera/CameraManager+VideoConfiguration.swift` (lines 79–83):

```swift
var availableZoomFactors: [CGFloat] {
    guard let device = currentDevice else { return [] }
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
    return [device.minAvailableVideoZoomFactor] + switchOvers
}
```

`backLenses` is the authoritative list of physical lenses and their optical factors, populated in `buildBackLensMap()` on session start. It already contains the optical zoom factors relative to wide = 1×. However, those factors are relative to wide-angle, while `setZoom` uses `device.videoZoomFactor` which is a multiplier on the current physical device's minimum. For a wide camera (optical factor = 1.0), 1.0× maps to zoom factor = 1.0. For the ultra-wide (optical factor = 0.5), the device itself only zooms from its own minimum. So zoom factors must be read from `device.minAvailableVideoZoomFactor` and `device.maxAvailableVideoZoomFactor` — not from backLenses.

The correct fix: for optical zoom lock, the only meaningful stops are `minAvailableVideoZoomFactor` and `1.0` (native optical zoom of the current physical lens). Digital zoom above 1.0× on a physical camera is always digital. So optical lock should snap to `[minAvailableVideoZoomFactor, 1.0]` filtered to what the device supports.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CameraManager+VideoConfiguration.swift`

**Out of scope:**
- `setZoom` in the same file — the caller of `availableZoomFactors`, no changes needed.
- `CameraView+LensSwitcher.swift` — lens switcher handles physical lens switching separately, not via zoom lock.

## Git workflow

- Branch: `advisor/006-optical-zoom-lock`
- Single commit; message: `fix: availableZoomFactors returns physical-camera optical stops`

## Steps

### Step 1: Replace `availableZoomFactors`

In `CameraManager+VideoConfiguration.swift`, replace:

```swift
var availableZoomFactors: [CGFloat] {
    guard let device = currentDevice else { return [] }
    let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
    return [device.minAvailableVideoZoomFactor] + switchOvers
}
```

With:

```swift
// Returns the optical-only zoom stops for the current physical camera.
// Physical cameras have exactly one optical zoom: their minimum (= 1× native glass).
// virtualDeviceSwitchOverVideoZoomFactors is empty on physical cameras — use
// minAvailableVideoZoomFactor and 1.0 as the two stops (min may equal 1.0 on wide).
var availableZoomFactors: [CGFloat] {
    guard let device = currentDevice else { return [1.0] }
    let minFactor = device.minAvailableVideoZoomFactor
    // Deduplicate: if min is already 1.0, return a single-element array.
    return minFactor < 1.0 ? [minFactor, 1.0] : [1.0]
}
```

This ensures:
- Ultra-wide (min ≈ 0.5): returns `[0.5, 1.0]` — lock snaps to native ultra-wide or native 1× on same physical sensor.
- Wide (min = 1.0): returns `[1.0]` — lock snaps to 1×, preventing any digital zoom.
- Telephoto (min = 1.0): returns `[1.0]` — same.

**Verify**: `grep -A6 "var availableZoomFactors" fexer/Camera/CameraManager+VideoConfiguration.swift` → shows the new implementation

### Step 2: Build and test

**Verify**: build → `BUILD SUCCEEDED`
**Verify**: tests → all passed

## Test plan

No new automated test (requires physical device with multiple lenses). Manual verification:

1. Enable optical zoom lock in the quick access bar.
2. Pinch to zoom: verify the zoom snaps only to whole-glass optical factors and cannot go to intermediate digital zoom values.
3. Switch to ultra-wide lens: verify zoom lock allows both the ultra-wide stop (≈0.5×) and 1× but not e.g. 0.7×.

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -n "virtualDeviceSwitchOverVideoZoomFactors" fexer/Camera/CameraManager+VideoConfiguration.swift` → no matches (old code removed)
- [ ] No files outside `fexer/Camera/CameraManager+VideoConfiguration.swift` are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- `setZoom` uses `availableZoomFactors` in a way that breaks if only 1 element is returned — inspect the `min(by:)` call; it handles single-element arrays correctly.
- Device reports `minAvailableVideoZoomFactor > 1.0` for some exotic hardware — add a `fxClamped` to ensure the returned values are ≥ minAvailableVideoZoomFactor.

## Maintenance notes

- If a future mode (e.g., digital tele-assist) needs to add virtual stops beyond 1×, extend `availableZoomFactors` with those. The `setZoom` snap logic is already correct.
- This change does NOT affect `backLenses` or the lens switcher — those are for discrete physical lens switching, not continuous zoom.
