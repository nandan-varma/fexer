# Style System — LUTs, Styles, Editing

Scope: photo styles, LUT loading (cube files + procedural fallback), thumbnail rendering, and
non-destructive post-capture editing. Read with [docs/architecture.md](architecture.md)
(isolation notes for `LUTLoader` / `StylePreviewRenderer` / `StyleTransforms`).

## Styles

`PhotoStyle.catalog` (Models/PhotoStyle.swift) defines 21 styles across Film / Genre / Mood
categories. Each style references a `.cube` filename in `Resources/LUTs/` (21 files).

## LUT loading (Utilities/LUTLoader.swift)

```text
LUTLoader.effectiveLUT(for: style)
  ├── tries load(filename:) — parses the .cube file from the bundle if present
  └── falls back to generateProcedural(name:) using StyleTransforms.params(for:)
        → applies saturation, contrast, exposure, warmth, tint, shadow lift, 3-way color
        → bakes a 17³ LUT (4913 entries) into NSData, cached in NSCache
        → cache key "__proc_<name>_<dim>"
```

- `.cube` parsing: plain text, B-major order; RGB padded to RGBA for
  `CIColorCubeWithColorSpace`.
- **Thread safety:** `LUTLoader` is fully nonisolated (`nonisolated static let shared`,
  `nonisolated(unsafe)` NSData / NSCache, immutable entries) — it is called from the camera
  pipeline. Never add MainActor state to it.

## StyleTransforms (Styles/StyleTransforms.swift)

Per-style parametric definitions: `nonisolated static params(for:)` + `apply(...)` — pure
functions, callable off the MainActor. `StyleParams` is a `nonisolated struct`.

## Live previews (Styles/StylePreviewRenderer.swift + StylesViewModel)

- `StylePreviewRenderer` generates thumbnails from the live frame by applying the same
  `LUTLoader.effectiveLUT` path (all public methods `nonisolated`;
  `OSAllocatedUnfairLock` inside for thread safety).
- Thumbnails are requested in `.onAppear`; if `lastFramePixelBuffer` is nil at that point
  (camera not started yet), `StylesViewModel.retryPendingThumbnailsOnce()` retries on the
  first `onPixelBuffer` callback.
- **LUT-build failure falls back to the UNPROCESSED image** — the completion is always
  called (deliberate behavior change from the original code, which silently never called
  completion on failure). Do not "fix" it back.

## Non-destructive editing (Models/EditState.swift)

All post-capture adjustments are applied non-destructively; the original pixel data is never
mutated — the filter chain is re-rendered on export. Property groups:

**Basic adjustments** (each with a `CIFilter` and documented range in the struct):

| Property | CIFilter | Range |
| --- | --- | --- |
| `exposure` | CIExposureAdjust inputEV | -2…+2 |
| `contrast` | CIColorControls inputContrast delta | -0.5…+0.5 |
| `shadows` | CIHighlightShadowAdjust inputShadowAmount | -1…+1 |
| `highlights` | CIHighlightShadowAdjust inputHighlightAmount | -1…+1 |
| `saturation` | CIColorControls inputSaturation delta | -1…+1 |
| `vibrance` | CIVibrance inputAmount | -1…+1 |
| `warmth` | CITemperatureAndTint shift | -1…+1 |
| `sharpness` | CISharpenLuminance | 0…1 |
| `vignette` | CIVignette inputIntensity | 0…1 |

**HSL**: 8 per-hue bands (`hslRed` … `hslMagenta`, each `HSLBand { hue, saturation,
luminance }`, `isNonZero` is `nonisolated`).

**Curves**: 4 tone curves (`curveR`, `curveG`, `curveB`, `curvePrimary`) as
`[SIMD2<Float>]` point arrays, defaulting to `identityCurve`.

**Crop / orientation**: `cropRect` (normalized 0…1, nil = full), `cropAspectRatio`,
`cropZoom`, `cropCenterX/Y`, `rotationDegrees` (-45…+45, snaps to 0 on double-tap),
`quarterTurns`, `isFlippedHorizontally`.

**Imported LUT**: `importedLUTBookmark: Data?` (security-scoped bookmark for a user-imported
.cube via `LUTImporterView`).

`EditView.swift` presents these as sliders with a before/after toggle. **`EditView.swift` was
deliberately NOT split into extensions** (an attempted split was judged too invasive) — keep
it whole.

## LUT file rules

`.cube` files belong in `fexer/Resources/LUTs/`. Filenames must match `PhotoStyle.catalog`
entries in `Models/PhotoStyle.swift`.
