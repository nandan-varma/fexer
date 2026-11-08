# Fexer: App Store Connect reference

Replaces `FEXER.md` from `~/dev` (last updated 2026-09-24). Live state comes from `asc`, so this file keeps only static facts and decisions. Account-level signing is in `helpers sign guide agents`; Apple lessons are in `~/dev/_docs/apple-gotchas.md`.
Same role as `apps/NightShift/ASC.md`.

## Identity
| | |
|---|---|
| App name / subtitle | **Fexer - Pro Camera** / "Manual camera & film LUTs" |
| Bundle ID | `com.nandanvarma.fexer` |
| Apple ID (app) | `6794734410` |
| SKU | `fexer-ios` |
| Category | Photo & Video (no secondary) |
| Price | Free, all 175 countries/regions. No in-app purchases or subscriptions |
| Primary language | English (U.S.) |
| Team ID | `72CW7UW6RB` |

Live state (2026-11-08): iOS 1.0 `READY_FOR_SALE`; builds 1-5 all `VALID` (build 5 uploaded 2026-09-24, TestFlight only). Check any time:
```sh
asc versions list --app 6794734410 && asc builds list --app 6794734410
```
`project.yml` is at `MARKETING_VERSION: '2.0'`, `CURRENT_PROJECT_VERSION: 5`. There is no 2.0 App Store version in ASC yet, so create one and attach a build before submitting.

## Signing
- Release: manual signing, `Apple Distribution`, profile "fexer App Store Testflight". These keys live in **`project.yml`** (`targets.Fexer.settings.configs.Release`), never hand-edited into the generated `.pbxproj`. Debug stays on automatic signing.
- Certificate, profile and API-key details change per machine; use `helpers whoami`, `asc certificates list`, `asc profiles list`.
- `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` (no network, no export-compliance prompt).
- `CURRENT_PROJECT_VERSION` is the build number: bump it for every upload, independent of `MARKETING_VERSION`.
- `TARGETED_DEVICE_FAMILY = 1` (iPhone only) on purpose. A universal build requires iPad screenshots, and the app isn't iPad-tuned. To add iPad later: set `"1,2"`, capture iPad screenshots, bump the build, re-archive. An already-uploaded build can't be retroactively fixed (`helpers sign guide app-store`).

## Release a new build
Follow `helpers sign guide app-store`, then `asc builds upload --ipa … --wait` and `asc publish …` (or the `asc-release-flow` skill). A Developer-role API key can't edit metadata, so "What's New" and attaching a build need the browser or an Admin key.
TestFlight: internal group "Internal" has automatic distribution on, so every upload auto-attaches (no Beta App Review for internal testers).

## Metadata decisions (text itself lives in ASC)
- Description, keywords, promo text: written from the README feature list (manual controls, 21 film LUTs, RAW/ProRes, viewfinder tools, non-destructive editing). Edit in ASC.
- Screenshots: 3 device-framed iPhone 6.5" shots (1284×2778) from real device captures.
- Age rating 4+. Content Rights: no third-party content.
- **App Privacy: "Data Not Collected"**, verified by grepping the code for `URLSession` and analytics SDKs (none). Any future network call or SDK means revisiting this; it is a compliance commitment.
- App Review: contact Nandan Varma; sign-in not required; notes say the camera needs a physical device (no Simulator).
- URLs: privacy `https://fexer.nandan.fyi/privacy`, support `/support`, marketing `https://fexer.nandan.fyi`. Copyright "2026 Nandan Varma". The site (Astro + Tailwind + Vercel adapter) was dropped when the app was rewritten (`CLAUDE.md`: "marketing site has not yet been rebuilt"; `.archived/` has no `web/`), so those URLs may be stale.

## Open items
- EU trader status (Digital Services Act banner in Business settings) is unresolved. It doesn't block review, but matters for EU distribution.
- If 2.0 gets rejected, read `appStoreReviewDetail` and the rejection email; likely causes are a reviewer without the multi-lens hardware fexer assumes.
