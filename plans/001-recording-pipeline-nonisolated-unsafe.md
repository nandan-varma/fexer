# Plan 001: Mark all recording-pipeline vars `nonisolated(unsafe)`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 99fab46..HEAD -- fexer/Camera/CameraManager.swift`
> If the file changed since this plan was written, compare the "Current state"
> excerpts against live code before proceeding; on a mismatch treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: correctness
- **Planned at**: commit `99fab46`, 2026-07-04

## Why this matters

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes every property on `CameraManager` implicitly `@MainActor`. Several recording-pipeline vars are read and written exclusively on `sessionQueue` (a background GCD queue) — never from the main actor. Swift's actor isolation system doesn't know this, so it treats them as MainActor state. The compiler allows the access today because the code predates strict concurrency enforcement, but in Swift 6 strict mode these are actor isolation violations that could cause data races at runtime. The CLAUDE.md explicitly documents this pattern and requires these vars to be `nonisolated(unsafe)` and `@ObservationIgnored`.

Two vars (`assetWriter`, `audioWriterInput`) are already correctly annotated. Seven more are not.

## Current state

File: `fexer/Camera/CameraManager.swift` (lines 72–88):

```swift
// assetWriter and audioWriterInput — correctly annotated
@ObservationIgnored nonisolated(unsafe) var assetWriter: AVAssetWriter?
var videoWriterInput: AVAssetWriterInput?                          // ← MISSING
@ObservationIgnored nonisolated(unsafe) var audioWriterInput: AVAssetWriterInput?
var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?      // ← MISSING
var isWaitingToRecord = false                                       // ← MISSING
var pendingRecordingLocation: CLLocation?                          // ← MISSING
var pendingRecordingStyleName: String?                             // ← MISSING

// ...
var _captureBusy = false                                           // ← MISSING
var pendingBracketCompletions = 0                                  // ← MISSING
```

All seven missing vars are accessed **only** on `sessionQueue` and never read from `@MainActor` code. The design doc (`CLAUDE.md`, section "nonisolated(unsafe) pattern") explicitly requires this annotation for all of them.

**Convention to follow:** Match the style of the two already-annotated vars:
```swift
@ObservationIgnored nonisolated(unsafe) var assetWriter: AVAssetWriter?
```
Both attributes required: `@ObservationIgnored` suppresses `@Observable` property tracking (which would try to post changes on MainActor), and `nonisolated(unsafe)` bypasses the actor isolation checker.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build (check only) | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 \| grep -E "error:\|BUILD SUCCEEDED\|BUILD FAILED"` | `BUILD SUCCEEDED` |
| Unit tests | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project fexer.xcodeproj -scheme fexer -destination "platform=iOS Simulator,name=iPhone 17" test 2>&1 \| grep -E "error:\|Executed\|passed\|failed"` | all passed |

## Scope

**In scope** (only file to modify):
- `fexer/Camera/CameraManager.swift`

**Out of scope** (do NOT touch):
- Any file that reads these vars — they compile fine without changes; the annotation fixes the declaration site only.
- `CameraManager+VideoRecording.swift` — uses the vars but doesn't declare them.

## Git workflow

- Branch: `advisor/001-nonisolated-unsafe`
- Single commit; message style: `fix: mark recording-pipeline vars nonisolated(unsafe)`

## Steps

### Step 1: Add `@ObservationIgnored nonisolated(unsafe)` to the seven vars

Open `fexer/Camera/CameraManager.swift`. Find the block at lines 72–88. Apply exactly these seven changes, one per declaration:

**Before:**
```swift
var videoWriterInput: AVAssetWriterInput?
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var videoWriterInput: AVAssetWriterInput?
```

**Before:**
```swift
var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
```

**Before:**
```swift
var isWaitingToRecord = false
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var isWaitingToRecord = false
```

**Before:**
```swift
var pendingRecordingLocation: CLLocation?
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var pendingRecordingLocation: CLLocation?
```

**Before:**
```swift
var pendingRecordingStyleName: String?
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var pendingRecordingStyleName: String?
```

**Before:**
```swift
var _captureBusy = false
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var _captureBusy = false
```

**Before:**
```swift
var pendingBracketCompletions = 0
```
**After:**
```swift
@ObservationIgnored nonisolated(unsafe) var pendingBracketCompletions = 0
```

**Verify**: `git diff fexer/Camera/CameraManager.swift | grep "^+" | grep -v "^+++" | wc -l` → 7 added lines

### Step 2: Build clean

Run the build command. Expect `BUILD SUCCEEDED`. If you see actor-isolation errors on the annotated vars, the annotations were applied incorrectly — check for typos.

**Verify**: build command → `BUILD SUCCEEDED`

### Step 3: Run unit tests

**Verify**: test command → `Executed N tests, with 0 failures`

## Test plan

No new tests needed. The change is a declaration-site annotation that fixes an isolation marker. Existing tests in `Tests/fexerTests/CameraManagerTests.swift` cover the recording start/stop state machine and will continue to pass. The annotation is verified by the build succeeding without actor-isolation errors.

## Done criteria

- [ ] Build exits 0 with `BUILD SUCCEEDED`
- [ ] All unit tests pass
- [ ] `git diff fexer/Camera/CameraManager.swift | grep "nonisolated(unsafe)" | wc -l` → 9 (2 existing + 7 new)
- [ ] No files outside `fexer/Camera/CameraManager.swift` are modified
- [ ] `plans/README.md` status row updated to DONE

## STOP conditions

- The code at lines 72–88 doesn't match the "Current state" excerpt (codebase drifted).
- Build produces actor-isolation errors on these vars after annotation — means the project's Swift settings changed.
- Any test failure after the change.

## Maintenance notes

- All future recording-pipeline vars that are sessionQueue-only must receive both annotations. The pattern is documented in CLAUDE.md ("nonisolated(unsafe) pattern").
- `@ObservationIgnored` is load-bearing: without it, `@Observable`'s macro generates `_$observationRegistrar.access(keyPath:)` calls that expect MainActor context, which would crash on sessionQueue.
