# Handoff: continuing Fuji Drop locally

Written Nov 27, 2026 when development moved from a cloud session (no Mac, builds via GitHub
Actions) to Claude Code running on the owner's Mac.

## What this is

An iPhone app (iPhone 16, iOS 27.2) that pulls a day's shots off a Fujifilm X-T1 over USB-C,
groups them into moments, suggests the best frame, lets the owner compare and pick, and saves
picks to Apple Photos as RAW+JPEG. Background: [leverage-research.md](leverage-research.md).
Measured results: [spike-findings.md](spike-findings.md). Read both first.

Branch: `claude/optimistic-meitner-15tlsd`. Commit and push there.

## Owner's preferences

- Shoots **RAW only** (no in-camera JPEG); edits in Capture One / Apple Photos, so Fuji colors
  don't matter. The RAF must be the Photos editing base (done; shows as "RAW+JPEG").
- Wants a **photo-first UI**: big images, minimal metadata and controls.
- **Grouping defaults are confirmed** (burst 3 s, split Δ > 0.6, join 180 s / Δ < 0.3).

## Build and run on the Mac

```sh
xcodegen generate            # after adding/removing files; Config/Local.xcconfig holds team + bundle prefix
xcodebuild -project FujiDrop.xcodeproj -scheme FujiDrop -destination 'generic/platform=iOS' build
swift test --package-path Packages/FujiDropKit
```

Install/launch on the iPhone over Wi-Fi with `xcrun devicectl` (list devices with
`xcrun devicectl list devices`). The camera can only be tested on the phone, by the owner.
The app's log mirrors to the console under subsystem `FujiDrop`, and to Settings › Log in the app.

## Layout

- `Packages/FujiDropKit`: camera session (ImageCaptureCore), PTP + RAF header parsing, preview
  cache, moment grouping, time sampling, Vision feature prints, RAW→JPEG rendering, Photos saving.
  Pure-logic parts have XCTest tests.
- `Apps/FujiDrop`: the main app. Connect → days (collage per day) → moments feed (one
  full-width photo per moment) → moment detail (frames full width, tap to zoom). Settings sheet
  has grouping sliders, a "show grouping details" toggle, preview storage, log, and disconnect.
- `Apps/Spike`: the X-T1 spike app used to answer the risk questions. Keep for reference.
- `.github/workflows/build.yml`: CI on GitHub's macOS runners (Xcode 26.6 / iOS 26.5 SDK only).

## Fixed: grey collages and moment photos

Day collages and moment photos stayed grey: the preview queue found cached previews instantly but
thumbnails never appeared. Cause: blocking ImageIO + Vision work in `Task.detached` starved Swift's
cooperative thread pool. Commit `10780b0` moved it to GCD queues (`Apps/FujiDrop/Background.swift`).
**Verified on device Nov 26, 2026:** cached previews decode in 0.03–0.04 s, Vision prints in
0.2–0.3 s, and collages fill in. Keep blocking work off the cooperative pool (use `Background`).

## Connection lifecycle (Nov 27, 2026, not yet checked on device)

- Unplugging mid-session keeps everything and shows `ReconnectOverlay` over the current screen
  (also over compare and the zoom sheet, via `.reconnectOverlay(model)`). Camera work stops;
  analysis of previews already on disk carries on.
- Reconnecting the same camera (`CameraSession.cameraID`: name + serial, else name) resumes:
  shots are rebuilt from the new catalog and keep their analysis when `Shot.key`
  (camera/name-size) matches; files gone from the card drop out ("Not on this card" screens);
  the open day re-queues. Late results only land if the key still matches.
- A different camera clears the session and pops to the day list. Settings › Disconnect ends
  the session and returns to Connect. Previews are cached per camera (`PreviewCache.scoped`).
- Picks are keyed by `Shot.key` (`picks.v2` in UserDefaults; earlier picks were dropped).

## Gotchas learned the hard way

- ImageCaptureCore callbacks can fire **more than once** (seen with
  `resetControlAuthorization`). Always bridge through `CameraSession.withTimeout` (resume-once).
- iOS **denies camera control** without prompting, so PTP commands (clock sync) get no answer.
  Contents access (files, partial reads, downloads) works.
- `xcodegen generate` wipes signing chosen in Xcode's UI; keep it in `Config/Local.xcconfig`.
- iOS 27 APIs (`originalResourceChoice`) are guarded with `#if compiler(>=6.4)` because CI only
  has the iOS 26.5 SDK. Local Xcode 27.2 compiles them.
- `.iOS(.v26)` in Package.swift needs `swift-tools-version: 6.2`.
- The X-T1's USB mode must be **MTP(PTP)**; cable is USB-C to micro-USB (data-capable).

## Next steps after the bug

1. ~~Best-shot scoring~~ (built Nov 27, 2026, **not yet checked on device**): `ShotScorer` measures
   focus (Laplacian variance, sharpest quarter of 64 px tiles on the faces or salient subject),
   face capture quality and aesthetics on each 1920 px preview; `BestShot` ranks within a moment
   (focus 55 %, aesthetics 25 %, faces 20 % when any frame has one). The feed's hero is the
   suggested pick once all frames are scored; the detail view stars it. Turn on "Show grouping
   details" to see each part of the score, and calibrate the weights on real bursts. Scores
   aren't cached on disk yet (recomputed each connect, ~0.1–0.3 s per shot expected).
2. ~~Compare screen~~ (built Nov 27, 2026, **not yet checked on device**): Compare in a moment's
   detail view (toolbar, or long-press a frame) opens two frames with zoom/pan locked together
   (`ZoomGroup` in `Zoomable.swift`). Winner stays: top/left is the favourite, bottom/right the
   challenger; tap the filmstrip to challenge, "Pick this" swaps, "Pick" saves. Picks persist in
   UserDefaults keyed by file name + size, one per moment; long-press a frame to pick/unpick.
   Frames show tips for likely flaws ("Soft focus", "Eyes closed", "Face unclear";
   `BestShot.Flaw`), which also cost 25 % of the score each. Eyes closed uses Vision landmark eye
   outline height/width < 0.15 on faces ≥ 6 % of frame width; "eyes" in the details label shows
   the value for calibration.
   **Full resolution** (built Nov 27, 2026, not yet checked on device): opening compare downloads
   both shown frames' RAFs (`ImportModel.rawURL`, kept in `RawCache`, last 6, cleared on
   disconnect) and decodes them with `RAWRenderer.renderImage` on a serial queue; each pane
   swaps the preview for the full image with the same viewport and shows a "RAW" badge.
   The preview queue pauses while a RAF downloads. Compare allows 8× zoom (100 % ≈ 4.2×
   stacked, ≈ 5.5× side by side). Saving a pick should reuse `rawURL` (cached after compare).
3. Save picks: `RAWRenderer` full-size JPEG + RAF via `PhotoSaver` (RAW as editing base), with
   location borrowed from nearby iPhone photos (camera clock can't be synced, so estimate offset).
4. Share: hand off to Instagram via the share sheet.
