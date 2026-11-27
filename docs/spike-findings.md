# X-T1 spike findings

Tested Nov 27, 2026 on an iPhone 16 with a Fujifilm X-T1 (USB mode **MTP(PTP)**, USB-C to micro-USB cable),
using the FujiDropSpike app. Answers the four "risks to test first" in [leverage-research.md](leverage-research.md).

| # | Question | Result |
| --- | --- | --- |
| 1 | ImageCaptureCore sees the X-T1 and lists its files | **Yes.** Contents access granted. First catalog load was slow; a second connection was fast (cause not yet known). |
| 2 | Previews over the cable are big enough to judge sharpness | **Thumbnails: no** (160×120, the EXIF thumbnail). In-camera JPEG download works but only exists when shooting FINE+RAW. RAF embedded preview via partial reads: *pending*. |
| 3 | RAF + JPEG save to Photos as one paired asset | **Yes.** Shows as a single RAW+JPEG item in Photos. |
| 4 | Camera clock over PTP | **No.** iOS denies control authorization without ever prompting (reset → NotDetermined, re-request → Denied). PTP commands get no answer at all. |

## Implications

- **Transfer:** ImageCaptureCore over USB is the day-1 path. No SD card reader fallback needed.
- **Scoring source:** the owner shoots RAW only, so in-camera JPEGs usually don't exist. The embedded
  RAF preview (partial read) is the candidate; the fallback is downloading whole RAFs.
- **Saving RAW-only shots:** Photos pairing works, but with no in-camera JPEG the app must render one
  (embedded preview or `CIRAWFilter`) or save the RAF alone. Decide after the preview test.
- **Clock:** drop clock sync. To line photos up with iPhone locations, estimate the camera's offset
  instead (e.g. compare an X-T1 shot with an iPhone shot of the same moment).
- **Catalog speed:** show files as they arrive rather than waiting for the full catalog. Re-measure
  a cold connection (new shots, camera power-cycled).
- **ImageCaptureCore callbacks can fire more than once** (seen with `resetControlAuthorization`).
  Every callback goes through a resume-once helper with a timeout.
