# CLAUDE.md

fexer — a portrait-orientation pro camera app for iPhone: SwiftUI UI, AVFoundation capture,
Core Image live filters, Metal preview. iOS 26.5 deployment target, Swift 5.0 mode,
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. ~80 Swift files / ~13.3k LOC.

## Read the docs — they are the single source of truth

All architecture knowledge lives in `docs/` (not here) so a sweep reads only what it needs.
**If code and docs disagree, code wins — fix the doc in the same change.**

| When working on… | Read |
| --- | --- |
| Anything at all (verification loop, layout, platform constraints) | [docs/project-overview.md](docs/project-overview.md) |
| Threading / isolation / CameraManager / CaptureProcessor | [docs/architecture.md](docs/architecture.md) |
| Frame pipeline, filters, preview, overlay positioning | [docs/camera-pipeline.md](docs/camera-pipeline.md) |
| Shutter, photo/video capture, shooting modes | [docs/capture-flow.md](docs/capture-flow.md) |
| Exposure / WB / focus / lens switching | [docs/manual-controls.md](docs/manual-controls.md) |
| Styles, LUTs, thumbnails, non-destructive editing | [docs/style-system.md](docs/style-system.md) |
| Views, @AppStorage keys, QuickAccessBar, shared components | [docs/ui-architecture.md](docs/ui-architecture.md) |
| House patterns, utilities, safety rules | [docs/conventions.md](docs/conventions.md) |

## Non-negotiable invariants (details in the docs)

1. **Threading** (docs/architecture.md): AVFoundation calls stay on `sessionQueue`
   (`com.fexer.session`); `@Observable` mutations cross back with `Task { @MainActor in }`;
   sessionQueue-only vars carry `@ObservationIgnored nonisolated(unsafe)`. **Do not extract
   sessionQueue closure bodies into helpers** — closure bodies are not isolation-checked in
   Swift 5 mode, function bodies are; extraction creates new build warnings.
2. **Verification baseline** (docs/project-overview.md): `BUILD SUCCEEDED` with zero
   warnings, `swiftlint lint --strict` 0 violations, 111/111 tests pass. Build commands and
   the project layout are in project-overview.md — read it before changing anything.
3. **Crash rules**: WB gains must be clamped to `[1.0, maxWhiteBalanceGain]` before
   `setWhiteBalanceModeLocked` (docs/manual-controls.md); Live Photo `.photo` + `.pairedVideo`
   must share one `PHAssetCreationRequest` (docs/capture-flow.md); `_captureBusy` is the only
   capture re-entry guard; zero force-unwraps / `fatalError` is the baseline
   (docs/conventions.md).

## Maintaining these docs

When a change alters documented behavior (new sessionQueue var, new @AppStorage key, changed
frame cadence, new QuickAccessItem, changed capture flow), update the corresponding doc in
the same change. The docs are how the next agent gets the whole picture without re-reading
the codebase.
