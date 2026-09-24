# fexer

A professional iOS camera app with manual controls, real-time color grading, and cinematic shooting modes. Built with SwiftUI, AVFoundation, and Core Image.

## Features

### Shooting Modes
- **Photo** — AEB bracketing, RAW / RAW+JPEG, watermark, LUT baking at capture
- **Video** — AVAssetWriter pipeline, 1080p / 4K, HEVC / H.264 / ProRes, GPS metadata
- **Long Exposure** — CIMaximumCompositing multi-frame blend (up to 60 frames)
- **Burst** — 10 frames at 100 ms intervals
- **Self-timer** — configurable delay and repeat count
- **Timelapse** — configurable interval, each frame saved as JPEG
- **Anamorphic** — 2× horizontal desqueeze, 2.39:1 crop guide
- **Night** *(partial)* — hardware low-light boost
- **Portrait** *(partial)* — depth data capture enabled

### Manual Controls
- ISO (25–6400) with auto toggle
- Shutter speed (1/8000 – 30 s) with auto toggle
- White balance (3200–7500 K) + tint (–150 green to +150 magenta), 7 presets
- Manual focus (lens position 0–1) with auto toggle
- AE lock (freezes current auto exposure values)
- Metering mode: Matrix / Center / Spot / Highlight-weighted
- EV compensation strip

### Viewfinder Overlays
- Grid: Thirds, Phi (golden ratio), Square, Diagonal
- Histogram: RGBL, Luma, Parade (RGB columns)
- Waveform monitor (IRE grid, color-coded clipping)
- Vectorscope (chroma wheel with Cb/Cr crosshairs)
- Electronic level (EMA-smoothed bubble)
- Focus peaking (edge detection, configurable color)
- Zebra stripes (animated over/under-exposure warning)
- False color (8-band luminance diagnostic)
- Clean view (all overlays hidden)

### Style System
21 color grades across three categories, applied as real-time LUTs and baked at capture:

| Category | Styles |
|---|---|
| Film | Portra 400, Tri-X BW, Velvia 50, Provia 100, HP5 BW, Gold 200, Agfa Vista |
| Genre | Street, Portrait Warm, Landscape, Astro, Golden Hour, Macro, Architecture |
| Mood | Cinematic, Faded Matte, Punchy, Dreamy, Noir BW, Warm Fade, Cool Mist |

.cube LUT files ship in the bundle; missing files fall back to procedural generation from `StyleTransforms.swift`.

### Post-Capture Editing
Non-destructive adjustments in `EditView`: exposure, contrast, shadows, highlights, saturation, vibrance, warmth, sharpness, vignette, crop, and rotation. Applied via a CI filter chain at export; source pixels are never modified.

## Requirements

- iOS 17+
- Physical device — camera does not work in Simulator
- Xcode 16+

## Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project fexer.xcodeproj -scheme fexer \
  -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

## Architecture Overview

- **Camera pipeline**: `AVCaptureVideoDataOutput` → `CaptureProcessor` (sessionQueue) → CI filter chain → `MTKView` at 60 fps
- **Threading**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; camera/filter work stays on `com.fexer.session`; cross-boundary state uses `OSAllocatedUnfairLock`
- **State**: `@Observable` throughout; `@AppStorage` for persisted settings (no UserDefaults wrapper)
- **Rendering**: Single `CIContext` backed by `MTLCreateSystemDefaultDevice()`, never recreated per frame

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.
