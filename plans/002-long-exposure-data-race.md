# Plan 002: Fix data race in `CaptureProcessor.beginLongExposureCapture`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CaptureProcessor.swift`
> On mismatch, treat as STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

`CaptureProcessor.beginLongExposureCapture` is called from `CameraView` on the MainActor. It writes `onLongExposureComplete` and `longExpDuration` directly, without holding any lock. These two properties are read on `sessionQueue` inside `captureOutput` — once per video frame (60fps). The result is a heap data race: the write from MainActor and the read from sessionQueue can overlap, causing torn reads or memory corruption. Swift's TSan will flag these as races in debug builds.

## Current state

File: `fexer/Camera/CaptureProcessor.swift`

**Declaration (lines 110–113):**
```swift
// Long exposure frame accumulation — all mutable state below is sessionQueue-only
// except longExpActiveLock (read/written from caller + sessionQueue)
private var longExpFrames: [CIImage] = []
private var longExpStart: CMTime = .invalid
var longExpDuration: Double = 4.0          // ← read on sessionQueue, written from MainActor
var onLongExposureComplete: ((CIImage) -> Void)?  // ← same problem
```

**`beginLongExposureCapture` (lines 119–127):**
```swift
func beginLongExposureCapture(duration: Double = 4.0, completion: @escaping (CIImage) -> Void) {
    guard !isLongExposureCapturing else {
        Logger.camera.warning("Long exposure already in progress, ignoring duplicate request")
        return
    }
    onLongExposureComplete = completion   // ← write from calling thread (MainActor)
    longExpDuration = duration            // ← write from calling thread (MainActor)
    longExpActiveLock.withLock { $0 = true }
}
```

**`captureOutput` reads at line ~193:**
```swift
if longExpStart.isValid && CMTimeGetSeconds(CMTimeSubtract(presentationTime, longExpStart)) >= longExpDuration {
    // ...
    let callback = onLongExposureComplete
    onLongExposureComplete = nil
```

**`cancelLongExposureCapture` (lines 130–135):** Already safe — its doc comment says "Must be called from sessionQueue" and `CameraManager.cancelLongExposureCapture()` dispatches it there.

**Existing pattern for thread-safe state:** All other cross-thread state uses `OSAllocatedUnfairLock`. Example from same file:
```swift
private let longExpActiveLock = OSAllocatedUnfairLock(initialState: false)
var isLongExposureCapturing: Bool { longExpActiveLock.withLock { $0 } }
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CaptureProcessor.swift`

**Out of scope:**
- `fexer/Camera/CameraManager+StillCapture.swift` — calls `cancelLongExposureCapture()` which dispatches to sessionQueue, no change needed.
- `fexer/Views/CameraView+Capture.swift` — caller of `beginLongExposureCapture`, no change needed.

## Git workflow

- Branch: `advisor/002-long-exposure-data-race`
- Single commit; message: `fix: guard onLongExposureComplete and longExpDuration with a lock`

## Steps

### Step 1: Add a lock for the two racing properties

In `CaptureProcessor.swift`, add a lock to protect `onLongExposureComplete` and `longExpDuration`. Place it with the other lock declarations (around line 106):

```swift
// Protects longExpDuration and onLongExposureComplete which cross
// the MainActor/sessionQueue boundary.
private let longExpParamsLock = OSAllocatedUnfairLock(
    initialState: (duration: 4.0, callback: Optional<(CIImage) -> Void>.none)
)
```

Remove the two raw var declarations:
```swift
var longExpDuration: Double = 4.0              // ← remove this line
var onLongExposureComplete: ((CIImage) -> Void)?  // ← remove this line
```

Add thread-safe accessors immediately after the new lock declaration:

```swift
var longExpDuration: Double {
    get { longExpParamsLock.withLock { $0.duration } }
    set { longExpParamsLock.withLock { $0.duration = newValue } }
}
var onLongExposureComplete: ((CIImage) -> Void)? {
    get { longExpParamsLock.withLock { $0.callback } }
    set { longExpParamsLock.withLock { $0.callback = newValue } }
}
```

**Important:** Keep the public API identical (same var names, same types) so all callers continue to compile without changes.

### Step 2: Build

**Verify**: build → `BUILD SUCCEEDED`

### Step 3: Run tests

**Verify**: tests → all passed

## Test plan

No new test is added — the fix is structural (replacing a raw var with a lock-protected computed var). The existing `CameraManagerTests.swift` long-exposure tests will continue to pass. TSan in a debug device build would previously flag this race; after the fix it will not.

If you want to verify mechanically: search for `longExpDuration` and `onLongExposureComplete` — every site should compile, and the lock protects every access.

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -n "var longExpDuration\|var onLongExposureComplete" fexer/Camera/CaptureProcessor.swift` shows computed-var forms (getter/setter with lock), not plain `var`
- [ ] `grep -n "longExpParamsLock" fexer/Camera/CaptureProcessor.swift | wc -l` → ≥ 4 lines (declaration + 2 getters + 2 setters ≥ 4)
- [ ] No files outside `fexer/Camera/CaptureProcessor.swift` are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- `longExpDuration` or `onLongExposureComplete` are read/written somewhere other than `CaptureProcessor.swift` in ways that don't go through the computed var — widen the scope to fix those call sites.
- Build fails because the tuple initializer syntax for `OSAllocatedUnfairLock` isn't accepted — use a small struct instead of a tuple for the lock state.
- Any test failure.

## Maintenance notes

- `longExpParamsLock` is acquired briefly per-frame when long exposure is active. The lock contention is negligible (held for nanoseconds per access).
- Any new property that crosses the MainActor/sessionQueue boundary on `CaptureProcessor` must follow the same pattern. See `imageLock`, `lutFilterLock`, `peakingColorLock`, `flagsLock` as exemplars.
