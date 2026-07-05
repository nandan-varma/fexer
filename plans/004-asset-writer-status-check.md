# Plan 004: Check `assetWriter.status` in `appendVideoFrame` and surface write errors to UI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager+VideoRecording.swift fexer/Camera/CameraManager.swift`
> On mismatch treat as STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 001 (so `assetWriter` is properly `nonisolated(unsafe)`)
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

When recording video and the device runs out of disk space (or any write error occurs), `AVAssetWriter.status` changes to `.failed`. The current `appendVideoFrame` only checks `input.isReadyForMoreMediaData` — not the writer's status. As a result:

- Frames continue to be pixel-buffer-rendered via `CIContext.shared.render` (GPU work) even though the writer cannot accept them.
- The error is only detected when `stopRecording` fires `finishWriting`, at which point the recording is silently discarded (just a log line at `Logger.camera.error`).
- The user sees no feedback and assumes the recording was saved.

The fix is two parts: (1) add a writer-status guard in `appendVideoFrame` so GPU work stops immediately on failure, and (2) add an `@Observable` error property on `CameraManager` so the view can surface a toast.

## Current state

**`appendVideoFrame` (`CameraManager+VideoRecording.swift:238-248`):**
```swift
func appendVideoFrame(_ ciImage: CIImage, time: CMTime) {
    guard let input = videoWriterInput,
          let adaptor = pixelBufferAdaptor,
          let pool = adaptor.pixelBufferPool,
          input.isReadyForMoreMediaData else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let pixelBuffer = pb else { return }
    CIContext.shared.render(ciImage, to: pixelBuffer)
    adaptor.append(pixelBuffer, withPresentationTime: time)
}
```

**`stopRecording` error path (`CameraManager+VideoRecording.swift:52-56`):**
```swift
writer.finishWriting {
    guard writer.status == .completed else {
        Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
        return   // ← silently discards; no UI notification
    }
    // saves to library ...
}
```

**`CameraManager` observable state (`CameraManager.swift`, around line 29):**
```swift
var isRecording = false
var recordingDuration: TimeInterval = 0
// ← no error property here
```

**`CameraView.swift` recording indicator (around line 268):**
```swift
if cameraManager.isRecording {
    HStack(spacing: 8) { ... }
}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CameraManager.swift` — add `recordingError` property
- `fexer/Camera/CameraManager+VideoRecording.swift` — add status guard in `appendVideoFrame`, post error in `stopRecording`
- `fexer/Views/CameraView.swift` — add error toast observation

**Out of scope:**
- `fexer/Views/CameraView+Lifecycle.swift` — no changes
- Any other file

## Git workflow

- Branch: `advisor/004-asset-writer-status-check`
- Single commit; message: `fix: guard appendVideoFrame on writer status, surface write errors to UI`

## Steps

### Step 1: Add `recordingError` property to `CameraManager`

In `CameraManager.swift`, in the "Video recording state (MainActor)" block (around lines 29–30), add:

```swift
// Non-nil when a recording failed mid-capture (e.g. disk full).
// Cleared when the next recording starts.
var recordingError: Error? = nil
```

### Step 2: Add writer-status guard to `appendVideoFrame`

In `CameraManager+VideoRecording.swift`, replace the `appendVideoFrame` function:

**Before:**
```swift
func appendVideoFrame(_ ciImage: CIImage, time: CMTime) {
    guard let input = videoWriterInput,
          let adaptor = pixelBufferAdaptor,
          let pool = adaptor.pixelBufferPool,
          input.isReadyForMoreMediaData else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let pixelBuffer = pb else { return }
    CIContext.shared.render(ciImage, to: pixelBuffer)
    adaptor.append(pixelBuffer, withPresentationTime: time)
}
```

**After:**
```swift
func appendVideoFrame(_ ciImage: CIImage, time: CMTime) {
    guard let writer = assetWriter, writer.status == .writing,
          let input = videoWriterInput,
          let adaptor = pixelBufferAdaptor,
          let pool = adaptor.pixelBufferPool,
          input.isReadyForMoreMediaData else { return }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
    guard let pixelBuffer = pb else { return }
    CIContext.shared.render(ciImage, to: pixelBuffer)
    adaptor.append(pixelBuffer, withPresentationTime: time)
}
```

The added `writer.status == .writing` guard stops GPU work immediately when the writer has failed.

### Step 3: Surface the error in `stopRecording`

In `CameraManager+VideoRecording.swift`, inside `writer.finishWriting { ... }`, replace the silent-discard block:

**Before:**
```swift
writer.finishWriting {
    guard writer.status == .completed else {
        Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
        return
    }
    performPhotoLibraryChange { ... }
}
```

**After:**
```swift
writer.finishWriting {
    guard writer.status == .completed else {
        let err = writer.error
        Logger.camera.error("Video writing failed: \(err?.localizedDescription ?? "unknown")")
        Task { @MainActor in self.recordingError = err }
        return
    }
    performPhotoLibraryChange { ... }
}
```

Also add `recordingError = nil` at the top of `startRecording` (on sessionQueue, before `isWaitingToRecord = true`):
```swift
Task { @MainActor in self.recordingError = nil }
```

### Step 4: Show error toast in `CameraView`

In `fexer/Views/CameraView.swift`, inside the `hudOverlayLayer` computed property, after the existing AEL toast block, add:

```swift
// ── Recording error toast ─────────────────────────────────────────────
if let err = cameraManager.recordingError {
    Text("Recording failed: \(err.localizedDescription)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.red.opacity(0.85), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, CameraView.quickBarHeight + 72)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
}
```

The toast auto-disappears when `recordingError` is cleared at the next recording start.

**Verify**: `grep -n "recordingError" fexer/Camera/CameraManager.swift fexer/Camera/CameraManager+VideoRecording.swift fexer/Views/CameraView.swift` → hits in all three files

### Step 5: Build and test

**Verify**: build → `BUILD SUCCEEDED`
**Verify**: tests → all passed

## Test plan

No automated test for disk-full (requires a device and disk manipulation). The error path is exercised by the guard in `appendVideoFrame` — if `writer.status != .writing`, the method returns early. The `recordingError` property being `@Observable` means SwiftUI will re-render the toast whenever it changes.

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -n "writer.status == .writing" fexer/Camera/CameraManager+VideoRecording.swift` → matches in `appendVideoFrame`
- [ ] `grep -n "recordingError" fexer/Camera/CameraManager.swift` → at least 1 hit (property declaration)
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- Plan 001 has not landed — `assetWriter` must be `nonisolated(unsafe)` before reading it in `appendVideoFrame` on sessionQueue.
- `CameraView.swift` already has a `recordingError`-like toast from a different branch — reconcile instead of duplicating.

## Maintenance notes

- The toast message uses `err.localizedDescription` which for `AVFoundation` errors is user-readable (e.g. "There is not enough disk space available"). No further formatting needed.
- `recordingError` is never written from sessionQueue directly — always via `Task { @MainActor in }` — to keep `@Observable` change tracking on MainActor.
