# Plan 003: Stop recording cleanly when AVCaptureSession is interrupted

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager.swift`
> On mismatch treat as STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 001 (lands first so all recording-pipeline vars are properly annotated)
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

When a phone call arrives (or Siri activates, or another app uses the microphone), AVFoundation posts `AVCaptureSession.wasInterruptedNotification`. The session pauses. If the user was recording video:

- `AVAssetWriter` stops receiving frames but its status is still `.writing` — until explicitly finalized.
- `isRecording` stays `true`, the `recordingTimer` keeps ticking, and `UIApplication.isIdleTimerDisabled` stays `true`.
- When the call ends and the session restarts (`interruptionEndedNotification`), the `onProcessedFrame` closure is still attached; new frames begin arriving and `appendVideoFrame` attempts to write to a writer that is no longer in a valid state (the session's time base resets).
- The resulting `.mov` file is either empty, corrupt, or never finalized.

The fix is to populate `sessionInterruptionObserver` (already declared at `CameraManager.swift:113`, never assigned) and call `stopRecording()` inside it when recording was active.

## Current state

File: `fexer/Camera/CameraManager.swift`

**Declaration (line 113):**
```swift
private var sessionInterruptionObserver: NSObjectProtocol?
```

**`startSession()` (lines 120–168):** Sets up `sessionErrorObserver`, `sessionInterruptionEndedObserver`, `cameraConnectObserver`, `cameraDisconnectObserver` — but `sessionInterruptionObserver` is never assigned.

**`stopSession()` (lines 171–188):** Tries to remove `sessionInterruptionObserver` as part of the cleanup array — no-op because it is nil.

**`stopRecording()` (lines 36–76 in `CameraManager+VideoRecording.swift`):** Public method; already handles the case where `assetWriter == nil` (guard returns early). Safe to call even when not recording.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CameraManager.swift` (add the observer in `startSession`)

**Out of scope:**
- `CameraManager+VideoRecording.swift` — `stopRecording()` needs no changes.
- `CameraView+Lifecycle.swift` — no changes.

## Git workflow

- Branch: `advisor/003-recording-interruption-handler`
- Single commit; message: `fix: stop recording on AVCaptureSession interruption`

## Steps

### Step 1: Assign `sessionInterruptionObserver` inside `startSession`

In `CameraManager.swift`, inside the `sessionQueue.async` block of `startSession()`, after the line that sets `sessionInterruptionEndedObserver`, add:

```swift
// Stop recording immediately when the session is interrupted (phone call,
// Siri, another app grabbing the microphone). The writer's time base resets
// after an interruption; continuing to append frames would corrupt the file.
self.sessionInterruptionObserver = NotificationCenter.default.addObserver(
    forName: AVCaptureSession.wasInterruptedNotification,
    object: session,
    queue: nil
) { [weak self] notification in
    guard let self else { return }
    // Only stop if recording is active — `stopRecording` is a no-op when not recording.
    if self.isRecording || self.isWaitingToRecord {
        Logger.camera.info("Session interrupted while recording — stopping recording")
        self.stopRecording()
    }
}
```

Place it immediately after the `sessionInterruptionEndedObserver` block (which begins around line 135). The exact insertion point is after the closing `}` of the `interruptionEndedObserver` block and before the `cameraConnectObserver` line.

**Risk note:** `isRecording` is read here without actor isolation (this closure fires on an arbitrary queue). `isRecording` is a `@MainActor` property. Read it safely by dispatching to `sessionQueue` where the check-and-stop is atomic:

Replace the pattern above with:

```swift
self.sessionInterruptionObserver = NotificationCenter.default.addObserver(
    forName: AVCaptureSession.wasInterruptedNotification,
    object: session,
    queue: nil
) { [weak self] _ in
    guard let self else { return }
    self.sessionQueue.async {
        if self.isWaitingToRecord || self.assetWriter != nil {
            Logger.camera.info("Session interrupted while recording — stopping")
            self.stopRecording()
        }
    }
}
```

This reads `isWaitingToRecord` and `assetWriter` on `sessionQueue` (safe after Plan 001 lands — both are `nonisolated(unsafe)`). `stopRecording()` already dispatches to `sessionQueue` with `sessionQueue.async`; calling it from sessionQueue nests one more async hop, which is fine.

**Verify**: `grep -n "sessionInterruptionObserver" fexer/Camera/CameraManager.swift` → shows the declaration (line ~113) AND an assignment inside `startSession`.

### Step 2: Build

**Verify**: build → `BUILD SUCCEEDED`

### Step 3: Run tests

**Verify**: tests → all passed

## Test plan

Interruption is an AVFoundation system event that can't be triggered in the Simulator. No new automated test is written. Manual test procedure:

1. Build and deploy to a physical device.
2. Start video recording in the app.
3. Have another person call the device (or ask Siri while the app is open).
4. Verify: recording stops, timecode resets to `00:00:00`, the recorded clip saves to the photo library.
5. After the call ends, verify the camera preview restarts (existing `interruptionEndedObserver` handles this).

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -c "sessionInterruptionObserver" fexer/Camera/CameraManager.swift` → 4 (declaration, assignment in startSession, removal in stopSession array, removal in deinit array)
- [ ] No files outside `fexer/Camera/CameraManager.swift` are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- Plan 001 has not landed — `isWaitingToRecord` and `assetWriter` must be `nonisolated(unsafe)` before reading them from a non-sessionQueue closure.
- `stopRecording` is not accessible from `CameraManager.swift` — it is defined in a `CameraManager` extension in `CameraManager+VideoRecording.swift` which is in the same module, so it is accessible.
- Build produces actor isolation errors — verify that Plan 001 was applied first.

## Maintenance notes

- If a second interruption reason is added in the future (e.g., `.contentSharingSession`), update the log message — the observer fires for all interruption reasons.
- `stopRecording` calls `Task { @MainActor in ... }` inside — this is fine; the task will execute after the sessionQueue block returns.
- `interruptionEndedObserver` already restarts the session on call end; no additional restart logic needed here.
