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

## Open bug (top priority)

**Day collages and moment photos stay grey.** Log shows the preview queue runs and finds
previews in the disk cache instantly ("done in 0.00 s"), but thumbnails never appear: no
decode-failure log, no ⚠︎ in the UI, progress stays at "0 of N". This started with the
preview-queue / photo-first changes; the earlier picker-based build loaded fine.

Hypothesis: blocking ImageIO + Vision work in `Task.detached` starved Swift's cooperative
thread pool. Commit `10780b0` moves it to GCD queues (`Apps/FujiDrop/Background.swift`), sets
thumbnails before Vision runs, and logs `Decode …` / `Vision …` timings. **Untested on device.**
Verify it; if still grey, the new log lines show which step stalls.

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

1. Best-shot scoring per moment on the 1920×1280 previews: Laplacian sharpness on the subject
   (MPS or vImage), `VNDetectFaceCaptureQualityRequest`, `CalculateImageAestheticsScoresRequest`.
   Use the top score as each moment's hero image instead of the middle frame.
2. Compare screen: synced zoom across candidates; for close calls, download the top 2–3 RAFs
   (~1.4 s each) and compare true 100% crops.
3. Save picks: `RAWRenderer` full-size JPEG + RAF via `PhotoSaver` (RAW as editing base), with
   location borrowed from nearby iPhone photos (camera clock can't be synced, so estimate offset).
4. Share: hand off to Instagram via the share sheet.
