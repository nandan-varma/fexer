# Plan 007: Throttle audio level updates to display rate

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager+VideoRecording.swift`
> On mismatch treat as STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: performance
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

The `AVCaptureAudioDataOutputSampleBufferDelegate` callback fires at the audio sample rate. At 48 kHz with a 1024-sample chunk (AVFoundation default), this is approximately 47 callbacks per second. Each callback currently creates a new MainActor `Task` to post the smoothed RMS level:

```swift
Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
```

That is ~47 Task allocations per second, ~47 MainActor scheduling hops per second, and ~47 SwiftUI property change notifications per second — all for a VU meter that renders at 60fps and where audio-level animation is visually smooth at 10–15 updates/sec. The smoothing coefficient (`0.7 / 0.3`) already limits perceptible change to ~3 effective updates per second, so most of the Tasks produce no visible difference.

The fix: maintain a simple sample counter in the delegate and only post to MainActor every Nth buffer (every ~100ms = every ~5 callbacks).

## Current state

File: `fexer/Camera/CameraManager+VideoRecording.swift` (lines 264–293):

```swift
extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Write to asset when recording
        if let input = audioWriterInput,
           input.isReadyForMoreMediaData,
           assetWriter?.status == .writing {
            input.append(sampleBuffer)
        }

        // Compute RMS audio level for the VU meter (~10fps update cadence)
        guard let channelData = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        // ... RMS computation ...
        let rms = sampleCount > 0 ? sqrt(sumSq / Float(sampleCount)) : 0
        Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }  // ← fires every callback
    }
}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope:**
- `fexer/Camera/CameraManager.swift` — add `audioSampleCount` property
- `fexer/Camera/CameraManager+VideoRecording.swift` — throttle the Task in the audio delegate

**Out of scope:** Everything else.

## Git workflow

- Branch: `advisor/007-audio-level-throttle`
- Single commit; message: `perf: throttle audio level updates to ~10fps`

## Steps

### Step 1: Add `audioSampleCount` to `CameraManager`

In `CameraManager.swift`, near the `audioLevel` declaration (around line 45):

```swift
// Live audio level (updated ~10fps while recording, 0.0=silence 1.0=peak)
var audioLevel: Float = 0.0

// Counter for throttling audio-level MainActor updates to ~10fps.
// Accessed only from the audio delegate (sessionQueue); nonisolated(unsafe).
@ObservationIgnored nonisolated(unsafe) var audioSampleCount: Int = 0
```

### Step 2: Throttle the MainActor dispatch

In `CameraManager+VideoRecording.swift`, inside `captureOutput(_:didOutput:from:)`, replace:

```swift
let rms = sampleCount > 0 ? sqrt(sumSq / Float(sampleCount)) : 0
Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
```

With:

```swift
let rms = sampleCount > 0 ? sqrt(sumSq / Float(sampleCount)) : 0
audioSampleCount &+= 1
// Post to MainActor every 5th buffer (~10fps at 48kHz/1024-sample chunks).
// The 0.7/0.3 smoothing already limits perceptible change rate; no quality loss.
if audioSampleCount % 5 == 0 {
    Task { @MainActor in self.audioLevel = self.audioLevel * 0.7 + rms * 0.3 }
}
```

`&+=` is overflow-safe addition (wraps without trapping). At 47 callbacks/sec, `audioSampleCount` overflows after ~5.9 years of continuous recording — harmless.

**Verify**: `grep -n "audioSampleCount" fexer/Camera/CameraManager.swift fexer/Camera/CameraManager+VideoRecording.swift` → hits in both files

### Step 3: Build and test

**Verify**: build → `BUILD SUCCEEDED`
**Verify**: tests → all passed

## Test plan

No automated test. The throttling is correct by construction: `% 5` on a monotonically increasing counter fires exactly every 5 calls. The audio meter's visual smoothness is maintained because the `0.7/0.3` filter averages across the 5-buffer window.

## Done criteria

- [ ] Build exits 0
- [ ] All tests pass
- [ ] `grep -n "audioSampleCount" fexer/Camera/CameraManager.swift` → 1 hit (declaration)
- [ ] `grep -n "audioSampleCount" fexer/Camera/CameraManager+VideoRecording.swift` → 2 hits (increment + modulo check)
- [ ] `grep -n "Task.*audioLevel" fexer/Camera/CameraManager+VideoRecording.swift` → 1 hit (inside the `if audioSampleCount % 5 == 0` block)
- [ ] No files outside the in-scope list are modified
- [ ] `plans/README.md` status updated

## STOP conditions

- The audio sample rate or buffer size is confirmed to be much lower than 48kHz/1024-sample (e.g. 8kHz), making `% 5` over-throttle to < 2fps — adjust divisor to `% 2` in that case.
- `audioSampleCount` is accessed from a second thread — if so, add `OSAllocatedUnfairLock` protection (same pattern as other locks in `CaptureProcessor`).

## Maintenance notes

- The throttle divisor `5` gives ~9.4 updates/sec at 48kHz/1024 samples. The `AudioLevelMeterView` animation in `CameraView.swift` uses `.animation(.easeInOut)` which smooths between samples; 10fps updates animate smoothly at 60fps display.
- If audio format changes to smaller chunk sizes (e.g. 512 samples → ~94 callbacks/sec), increase the divisor to `10` to maintain ~10fps updates.
