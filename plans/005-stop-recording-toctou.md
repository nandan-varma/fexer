# Plan 005: Fix TOCTOU in `stopRecording` — keep `assetWriter` non-nil until `finishWriting` completes

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager+VideoRecording.swift`
> On mismatch treat as STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 001
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

`stopRecording()` nils out `assetWriter` (and related vars) immediately on `sessionQueue`, then calls `writer.finishWriting { ... }`. `finishWriting`'s completion block runs on a separate system thread — not on `sessionQueue`. This means the window between `assetWriter = nil` and the completion block finishing is non-zero.

During that window, the guard at the top of `startRecording`:
```swift
guard !isWaitingToRecord && assetWriter == nil else { return }
```
…passes, and a new recording can start. The new `setupAssetWriter` creates a second `AVAssetWriter` pointing to a new temp file. Both the old `finishWriting` callback and the new writer now exist concurrently. The old callback's `performPhotoLibraryChange` races with the new writer's startup. In practice this is a corner case (user stops then immediately re-starts recording in < ~100ms) but it is a real TOCTOU.

The fix: add a `isFinishingRecording` flag that gates `startRecording` for the duration of `finishWriting`.

## Current state

File: `fexer/Camera/CameraManager+VideoRecording.swift`

**`stopRecording` (lines 36–76):**
```swift
func stopRecording() {
    sessionQueue.async { [self] in
        isWaitingToRecord = false
        processor.onProcessedFrame = nil
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        guard let writer = assetWriter else { return }
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        assetWriter = nil            // ← nils the guard BEFORE finishWriting completes
        videoWriterInput = nil
        audioWriterInput = nil
        pixelBufferAdaptor = nil
        let outputURL = writer.outputURL
        let savedLocation = pendingRecordingLocation
        pendingRecordingLocation = nil
        pendingRecordingStyleName = nil
        writer.finishWriting {
            // ← runs on system thread, not sessionQueue
            guard writer.status == .completed else { ... return }
            performPhotoLibraryChange { ... }
        }
        Task { @MainActor in ... isRecording = false ... }
    }
}
```

**`startRecording` guard (`CameraManager+VideoRecording.swift:19`):**
```swift
guard !isWaitingToRecord && assetWriter == nil else { return }
```

**Existing `nonisolated(unsafe)` vars (`CameraManager.swift:72–88`)** — after Plan 001 lands, `isWaitingToRecord` and `assetWriter` will be properly annotated.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CameraManager.swift` — add `isFinishingRecording` property
- `fexer/Camera/CameraManager+VideoRecording.swift` — use it in `startRecording` and `stopRecording`

**Out of scope:** Everything else.

## Git workflow

- Branch: `advisor/005-stop-recording-toctou`
- Single commit; message: `fix: guard startRecording against concurrent finishWriting`

## Steps

### Step 1: Add `isFinishingRecording` to `CameraManager`

In `CameraManager.swift`, in the `nonisolated(unsafe)` vars block (after Plan 001 it will look like):

```swift
@ObservationIgnored nonisolated(unsafe) var isWaitingToRecord = false
```

Add immediately after it:

```swift
// True from the moment stopRecording clears the writer vars until
// finishWriting's completion block fires. Gates startRecording from
// starting a new writer while the old one is still flushing.
@ObservationIgnored nonisolated(unsafe) var isFinishingRecording = false
```

### Step 2: Update `startRecording` guard

In `CameraManager+VideoRecording.swift`, change the guard:

**Before:**
```swift
guard !isWaitingToRecord && assetWriter == nil else { return }
```

**After:**
```swift
guard !isWaitingToRecord && !isFinishingRecording && assetWriter == nil else { return }
```

### Step 3: Set and clear `isFinishingRecording` in `stopRecording`

In `stopRecording`, after the `guard let writer = assetWriter else { return }` line, set the flag before clearing the writer vars:

```swift
isFinishingRecording = true
```

Then inside `writer.finishWriting { ... }`, at the very end (after `performPhotoLibraryChange` call — or after the early-return guard), dispatch back to sessionQueue to clear the flag:

```swift
writer.finishWriting {
    defer {
        self.sessionQueue.async { self.isFinishingRecording = false }
    }
    guard writer.status == .completed else {
        Logger.camera.error("Video writing failed: \(writer.error?.localizedDescription ?? "unknown")")
        return
    }
    performPhotoLibraryChange { ... }
}
```

The `defer` ensures `isFinishingRecording` is cleared whether writing succeeded or failed.

**Verify**: `grep -n "isFinishingRecording" fexer/Camera/CameraManager.swift fexer/Camera/CameraManager+VideoRecording.swift` → hits in both files (declaration + 3 uses)

### Step 4: Build and test

**Verify**: build → `BUILD SUCCEEDED`
**Verify**: tests → all passed

## Test plan

No automated test added (the race window is < 100ms and non-deterministic). Verified structurally: after `stopRecording` fires, `isFinishingRecording = true` is set on `sessionQueue` before any new `startRecording` call can evaluate the guard. The `finishWriting` completion always clears it via `sessionQueue.async`, which is serialized with any concurrent `startRecording` call.

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -c "isFinishingRecording" fexer/Camera/CameraManager.swift fexer/Camera/CameraManager+VideoRecording.swift` → total ≥ 4
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- Plan 001 has not landed — `isFinishingRecording` must also be `nonisolated(unsafe)` as part of Plan 001's scope (add it there if both plans are being executed together).
- `startRecording` is called from a code path other than `sessionQueue.async` — this plan assumes all recording state changes are serialized through `sessionQueue`.

## Maintenance notes

- `isFinishingRecording` is a sessionQueue-only var — it must stay `nonisolated(unsafe)` (see Plan 001 for the pattern).
- The `defer` in `finishWriting`'s block fires on the system thread used by `AVAssetWriter`; the `sessionQueue.async` hop makes the clear operation serial with any concurrent `startRecording`.
