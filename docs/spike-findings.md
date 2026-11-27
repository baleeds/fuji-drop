# X-T1 spike findings

Tested Nov 26–27, 2026 on an iPhone 16 (iOS 27.2.1) with a Fujifilm X-T1 (USB mode **MTP(PTP)**, USB-C to micro-USB cable),
using the FujiDropSpike app. Answers the four "risks to test first" in [leverage-research.md](leverage-research.md).

| # | Question | Result |
| --- | --- | --- |
| 1 | ImageCaptureCore sees the X-T1 and lists its files | **Yes.** Contents access granted. 941-file card catalogued in under 1 s on a later connection; the first-ever connection was slow (likely first-time setup). |
| 2 | Previews over the cable are big enough to judge sharpness | **Thumbnails: no** (160×120, the EXIF thumbnail). In-camera JPEG download works but only exists when shooting FINE+RAW. **RAF embedded preview via partial reads: 1920×1280, avg 682 KB in 107 ms (~560 shots/min)** vs 31–32 MB for the whole RAF. Fine for grouping, eyes and gross blur; subtle focus differences are hard to see by eye (about 2.5× downscale from 4896×3264). |
| 3 | RAF + JPEG save to Photos as one paired asset | **Yes.** Shows as a single RAW+JPEG item in Photos. |
| 4 | Camera clock over PTP | **No.** iOS denies control authorization without ever prompting (reset → NotDetermined, re-request → Denied). PTP commands get no answer at all (GetDeviceInfo timed out after 15 s), even though the camera reports `ICCameraDeviceCanAcceptPTPCommands`. |

Camera capabilities reported: `ICCameraDeviceSupportsHEIF`, `ICCameraDeviceCanDeleteOneFile`,
`ICCameraDeviceCanAcceptPTPCommands`.

**Full RAF download:** 33.3 MB in 1.41 s (23.6 MB/s), near the X-T1's USB 2.0 ceiling. Fetching the
top 3 candidates of a moment for full-size comparison costs about 4 s.

**On-phone JPEG render (RAW-only shot):** `CIRAWFilter` → 4896×3264 sRGB JPEG, 3.1 MB, in 1.35 s.
With the 1.4 s RAF download, saving a RAW-only pick to Photos takes about 3 s end to end.

## Implications

- **Transfer:** ImageCaptureCore over USB is the day-1 path. No SD card reader fallback needed.
- **Scoring source:** the owner shoots RAW only, so in-camera JPEGs usually don't exist. Use the
  1920×1280 embedded RAF preview (partial read) for grouping and automatic ranking of every shot.
- **Close calls:** for the top 2–3 candidates in a moment, download the full RAF and compare true 100%
  crops (decoded with `CIRAWFilter`). The picked RAF is downloaded anyway for saving.
- **Saving RAW-only shots (decided):** render a full-resolution JPEG from the RAF on the phone
  (`RAWRenderer`, Apple's default RAW look, sRGB, RAF EXIF copied) and save it paired with the RAF.
  Uses the in-camera JPEG when one exists. Fuji film-simulation looks are not reproduced, which is
  fine: the owner edits from RAW (Capture One / Photos), so the JPEG is only a share fallback.
- **RAW is the editing base (iOS 27):** saving sets `originalResourceChoice = .raw`. Confirmed in
  Photos: assets saved this way are labelled **RAW+JPEG**; without it they show **JPEG+RAW**
  (JPEG as original). Guarded by `#if compiler(>=6.4)` since CI runners only have the iOS 26.5 SDK.
- **Clock:** drop clock sync. To line photos up with iPhone locations, estimate the camera's offset
  instead (e.g. compare an X-T1 shot with an iPhone shot of the same moment).
- **Catalog speed:** show files as they arrive rather than waiting for the full catalog. Re-measure
  a cold connection (new shots, camera power-cycled).
- **ImageCaptureCore callbacks can fire more than once** (seen with `resetControlAuthorization`).
  Every callback goes through a resume-once helper with a timeout.
