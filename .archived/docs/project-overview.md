# Project Overview — fexer

Scope: what fexer is, the build/test/lint verification loop, project layout, Xcode project
mechanics, and platform constraints. **Read this before any code change** — it contains the
verification loop every change must pass — then read the subsystem doc for what you touch.

## What fexer is

A portrait-orientation pro camera app for iPhone: SwiftUI UI, AVFoundation capture, Core Image
live filters, Metal preview. ~80 Swift files / ~13.3k LOC.

- Deployment target **iOS 26.5**, `SWIFT_VERSION = 5.0` (Swift 5 mode — see
  [docs/architecture.md](architecture.md) for what that means for isolation checking),
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- CI (`.github/workflows/ci.yml`, on push/PR to `main`): device build → simulator test run →
  `swiftlint lint --strict`.

## Verification loop (build · test · lint)

```bash
# Build for device (no signing required for verification)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project fexer.xcodeproj -scheme fexer \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build

# Errors-only check (pipe-friendly)
... build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

# All unit tests (Simulator — no camera required)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project fexer.xcodeproj -scheme fexer \
  -destination "platform=iOS Simulator,name=iPhone 17" test \
  2>&1 | grep -E "error:|Executed|passed|failed"

# Run a single test class
... test -only-testing:fexerTests/EditStateTests 2>&1 | grep -E "error:|passed|failed"

# Lint (CI enforces --strict, so warnings are errors)
swiftlint lint --strict
```

**Baseline (do not regress):** `BUILD SUCCEEDED` with **zero warnings**, swiftlint **0
violations**, **111/111 tests pass**. A change that regresses any of these is a bug.

### Platform constraints

- **Deployment target iOS 26.5** — no `#available` guards needed for any AVFoundation,
  SwiftUI, or Swift concurrency API introduced before that. Use the latest symbol names
  directly (e.g. `AVCaptureDevice.wasConnectedNotification`, not the deprecated
  `.AVCaptureDeviceWasConnected`).
- **Camera does not work in Simulator.** All meaningful capture testing requires a physical
  iPhone. Unit tests cover models/utilities only.
- **SourceKit lies**: it indexes against the macOS SDK and reports false positives (UIKit
  "unavailable in macOS", cross-file references "not found"). Ignore them; `xcodebuild`
  against the iOS SDK is the truth.
- If the Simulator fails with "Busy (Application failed preflight checks)", shut it down
  (`xcrun simctl shutdown all`) and boot the device explicitly before retrying.

### Tests

- `Tests/fexerTests/` — CameraManagerTests (18), ViewModelTests (24), UtilitiesTests (11),
  and `fexerTests.swift` (58: PhotoStyle / EditState / enum tests). 111 tests total, all in
  the fexerTests target via the synchronized root group.

## Project layout

```text
fexer/
├── App/                          # AppState.swift — screen routing, quick-access bar order
├── Camera/                       # CameraManager (+KVO, +ManualControls, +StillCapture,
│                                 #   +VideoConfiguration, +VideoRecording), CaptureProcessor,
│                                 #   CameraPreview, CIKernel+Compile,
│                                 #   filters (FalseColorFilter, FocusPeakingFilter, ZebraFilter)
├── Models/                       # ShootingMode (+ QuickAccessItem + MeteringMode + WBPreset),
│                                 #   CaptureSettings, CapturedPhoto, EditState, VideoSettings, PhotoStyle
├── ViewModels/                   # CameraViewModel, StylesViewModel, GalleryViewModel
├── Utilities/                    # PermissionsManager, CaptureService, CaptureImagePipeline,
│                                 #   ExifReader, HistogramCalculator, LUTLoader, CIContext+Shared,
│                                 #   CapturePresetsManager, DeviceOrientationTracker, HapticManager
├── Styles/                       # StylesManager, LUTFilter, StyleTransforms, SceneClassifier,
│                                 #   StylePreviewRenderer
├── Views/
│   ├── CameraView.swift          # Main camera UI — layer composition, @AppStorage keys, gesture routing
│   ├── CameraView+Capture.swift / +ShootingModes.swift / +ShutterButton.swift
│   ├── CameraView+LensSwitcher.swift / +Lifecycle.swift
│   ├── ViewfinderView.swift      # MTKView + overlay composition
│   ├── ReviewView.swift, ReviewCarouselView.swift, EditView.swift
│   ├── GalleryView.swift, SettingsView.swift, OnboardingView.swift
│   ├── SplashView.swift, QuickAccessBar.swift, ApertureLogoView.swift
│   ├── Overlays/                 # Histogram, Waveform, Vectorscope, LevelIndicator, GridOverlay,
│   │                             #   FocusPeakingOverlay, ZebraOverlay, AudioLevelMeterView,
│   │                             #   EVOffsetIndicator, GestureHintOverlay
│   ├── ControlsPanel/            # ExposureRailView (top-bezel chip row), DialWheelView (jog dial)
│   ├── StylePicker/              # StylePickerView, StyleCategoryView, StyleThumbnailView,
│   │                             #   StyleBeforeAfterView, StyleAdjustmentsRow, CapturePresetsView,
│   │                             #   SliderThumb
│   └── SupportingTypes/          # CapturePhotoDelegate, ShutterButtonStyle, VolumeHUDSuppressor,
│                                 #   VolumeButtonHandler, ZoomDial, LUTImporterView,
│                                 #   SharedUIComponents
├── Resources/LUTs/               # 21× .cube LUT files
└── Tests/fexerTests/             # CameraManagerTests, ViewModelTests, UtilitiesTests
```

## Xcode project mechanics

- **New files are picked up automatically.** The project uses
  `PBXFileSystemSynchronizedRootGroup` (4 occurrences in `project.pbxproj`) — add a `.swift`
  file anywhere under `fexer/` and it compiles without touching the pbxproj.
- **Privacy keys live in pbxproj build settings**, not a separate Info.plist:
  `INFOPLIST_KEY_NS*` entries in both Debug and Release configs
  (`GENERATE_INFOPLIST_FILE = YES`). Edit them in `project.pbxproj`.
- **Orientation lock** is two layers: `AppDelegate.supportedInterfaceOrientationsFor` returns
  `.portrait`, plus `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone =
  UIInterfaceOrientationPortrait` in the pbxproj. Individual UI elements counter-rotate at
  runtime via `DeviceOrientationTracker` (see [docs/ui-architecture.md](ui-architecture.md)).

## Doc map

| Doc | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Threading model, isolation annotations, key classes — read for any CameraManager/CaptureProcessor work |
| [camera-pipeline.md](camera-pipeline.md) | Frame path, filter chain, locks, rotation, rendering, letterbox positioning |
| [capture-flow.md](capture-flow.md) | Shutter flow, capture variants, video recording, shooting modes |
| [manual-controls.md](manual-controls.md) | AE lock, top-bezel chip strip, WB, focus, lens switching |
| [style-system.md](style-system.md) | Styles, LUT loading, thumbnails, non-destructive editing |
| [ui-architecture.md](ui-architecture.md) | Views, @AppStorage keys, QuickAccessBar, shared components |
| [conventions.md](conventions.md) | House patterns (fxClamped, withLock, Logger…), utilities, safety rules |
