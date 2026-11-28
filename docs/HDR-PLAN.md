# LibRaw DNG pipeline and HDR merge: plan

Save shots as linear DNGs and merge exposure-bracketed landscape shots into one floating-point
linear DNG. The decode uses
LibRaw's Markesteijn demosaic instead of Apple's RAW engine, because X-Trans renders badly in
many editors. Written Nov 27, 2026 for a session on the local Mac, which has the X-T1, the
iPhone, Xcode and a desktop editor. Read `docs/HANDOFF.md` first for how the app works.

## Status (Nov 27, 2026): all six steps built; nothing checked on the phone yet

Steps 1–6 are implemented. Verified on the Mac with the owner's own files: brackets
DSCF2729–2731 (handheld AE BKT ±1) and DSCF2527–2529 (AE BKT with auto ISO, people walking)
merge aligned and ghost-free at 100 % in about 8 s; a single DNG save (DSCF3218) takes 3.0 s
and 51 MB, and its lossless JPEG tiles decode bit-identical to an uncompressed copy in an
independent decoder (tifffile + imagecodecs). Not yet run on the iPhone: check save and
merge times, memory, and that Photos accepts the DNG as the RAW of a RAW+JPEG pair.

Code: `HDR/` in FujiDropKit (`XTransDecoder`, `ColorCleanup`, `DNGWriter`, `LosslessJPEG`,
`LinearRenderer`, `DNGConverter`, `HDRMerger`, `HDRPipeline`, `MergeCache`,
`Acknowledgements`), `Moments/Brackets.swift`, and in the app `SaveQueue` (`SaveFormat`, DNG
saves, kept RAFs), `TuningView` (Settings › Saving), `ImportModel` (brackets, merged frames,
`savedFormats.v1`) and `MomentViewer` (Merge button).
Real-file tests: `FUJIDROP_TEST_RAF=<raf>`, `FUJIDROP_TEST_BRACKET=<raf>,<raf>,<raf>` and the
tone-curve calibration `FUJIDROP_TEST_RAFS=<raf>,…` (optionally `FUJIDROP_TEST_OUT=<dir>` to
keep outputs), best with `swift test -c release`.

Where the build differs from the plan below, and why:

- **Decode in parallel bands.** LibRaw's Markesteijn is single-threaded without OpenMP: 8 s
  per X-T1 frame on one Mac core. The decoder runs 4 LibRaw instances on overlapping
  `cropbox` bands (aligned to the 6×6 X-Trans pattern) and stitches them: 2.2 s. LibRaw is
  unchanged. Output matches a whole-frame decode except along LibRaw's own internal tile
  seams, which move.
- **Frames stay 16-bit** (LibRaw's white-balanced output plus its multipliers), ~96 MB each
  instead of 192 MB as floats; the merge converts strip by strip. `adjust_maximum_thr = 0`
  so every frame and band uses the same white point.
- **Bracket rule needs exposure compensation to change too.** EV differences alone flagged
  many bursts on the owner's cards (auto ISO drifting a stop mid-burst). Every frame must
  differ from every other in both ExposureBiasValue (≥ 0.6) and captured EV (≥ 0.5). AE BKT
  and dial brackets record the bias; a full-manual bracket (shutter only) isn't found.
  Brackets are found over the day's time order, and moments that split one are rejoined.
- **Warping happens while merging** (bilinear, from the inverted Vision homography), so no
  warped copies are kept. Vision's `warpTransform` maps floating → reference in
  bottom-left-origin coordinates (checked with a synthetic shift).
- **Deghosting compares per colour channel**, on an 8× smaller grid. Luminance alone missed
  a leg moving over ferns (same brightness, different colour).
- **DNG: `WhiteLevel` 1 is required** (Core Image renders float data without it as black,
  though the spec makes it the default), and **uncompressed**: Core Image can't decode
  Deflate-compressed float DNGs with any predictor (3, 34894, 34895; tifffile reads all of
  them). So a merge is ~100 MB. The Deflate path is kept behind `compress:` for desktop use.
- **BaselineExposure** is measured by rendering a ¼-size DNG of the merge with Core Image
  against the reference frame's embedded JPEG; the same render makes the 1024 px preview.
  The pairing JPEG is rendered from the DNG with `RAWRenderer` (now cross-platform).
- **The merged frame's "RAW" is its DNG**: `rawURL` returns it (merging again if the cache
  was pruned), so compare and `SaveQueue` work unchanged; saving reuses the merge's JPEG.
  Merges are kept in `Caches/Merges` (8 most recent) and remembered in `merges.v1`.

- **DNG saves use lossless JPEG, not Deflate.** Core Image doesn't decode Deflate in DNGs at
  all (16-bit integer with Predictor 2 failed too). Lossless JPEG (Compression 7, our own
  `LosslessJPEG` encoder) is what camera DNGs use and Core Image reads it: 51 MB per frame.
- **Tone curve chosen by measurement.** `LinearRendererTests` renders 16 of the owner's frames
  with four curves at matched brightness and scores them against the camera's JPEG. ACES
  (Narkowicz fit, per channel) was closest on 15 of 16 (8.4 levels mean difference; log S
  11.4, none 14.9, Hable 16.3). HDR merges now render their JPEG and preview the same way.
- **The 5×5 median runs 8 pixels at a time** through a sorting network (Batcher, pruned to the
  middle element) with `simd_min`/`simd_max`: cleanup went from 2.4 s to 0.28 s per frame,
  bit-identical output.

Still to do: everything on the phone (times, memory, Photos accepting DNG pairs and showing
them as RAW+JPEG, `PhotoSaver.editingBase`); `dng_validate`; Lightroom / Capture One (do the
Fujifilm camera profiles and lens corrections still apply to the DNG?); comparing DNG saves at
100 % with RAF saves; the high-ISO and DR-mode fixtures from the list below.

## Editing DNGs in Apple Photos: measured (Nov 27, 2026)

The owner found our DNGs (single saves and merges) reach "the edge of terrible" sooner than
RAFs when edited in Photos. Measured through Core Image's `CIRAWFilter` (Photos' RAW engine)
on the owner's frames, our DNG against the original RAF:

- **Noise reduction flags differ.** For a RAF, Core Image applies colour noise
  reduction (0.5) and sharpening (0.9) by default and offers luminance NR, detail, contrast
  and moiré controls. For our linear DNGs every one of those is unsupported: no NR, no
  sharpening, at all. No DNG tag turns them on (tried `NoiseProfile` in the raw IFD and
  IFD0, `BaselineNoise`, `BaselineSharpness`, `LinearResponseLimit`, camera-model tags, an
  older `DNGBackwardVersion`, all together). Apple's NR evidently lives in its demosaic
  stage, so *any* already-demosaiced (LinearRaw) DNG gets none. Pushing Shadows on an ISO
  1000 frame shows the sensor's noise unfiltered.
- **Highlights are not worse.** Matched at midtones and pushed +1.5 EV, the RAF's brightest
  areas blow (mean 252–254, no texture) while our DNG keeps texture (mean 166–227, spread
  25–83) on DSCF3218, DSCF3201, DSCF3463 and DSCF2516: Apple renders linear DNGs with a
  flatter highlight curve. Decoding with LibRaw `highlight = 1` (each channel to its own
  saturation instead of clipping at the first) only helps frames with real sensor clipping
  (DSCF3463: the share of the blown region still flat at −0.5 EV fell from 29 % to 15 %);
  not adopted yet.
- **White balance is close.** On a 24 × 16 grid of block averages, our DNG differs from the
  RAF by ΔE 0.6 (daylight) to 2.3 (tungsten) as shot, and ΔE 2–3 when the temperature is
  moved to anywhere between 2800 K and 7500 K (4.7 at 2800 K on the tungsten frame). A
  second colour matrix would help a little, not much. Photos shows a different tint number
  for the same neutral (RAF +23, DNG +8), so setting tint to a fixed value shifts them
  differently.

**But in practice:** the owner edited a single-frame DNG save in Photos and it held up as well
as the RAF of the same shot, so the missing NR flags above don't hurt in real use (our colour
cleanup may cover what matters). The fragile edits were merge-specific, and the merge tried
was the old one with blotchy skin (fixed since: reference-anchored weights). Still to compare:
the fixed merge against a single DNG in Photos. If merges remain worse, write them as 16-bit
integer + lossless JPEG like single saves (the reference frame's clip at 16383, leaving 2
stops of headroom for recovered highlights) instead of uncompressed half floats.

## Decisions already made

- **Scope:** DNG output for HDR merges, plus an optional "save as DNG" format for ordinary
  saves, since the study showed LibRaw beating Apple's decoding in general. RAF + JPEG stays the
  default until DNG saves are checked on the device.
- **Order:** decoder → DNG writer → DNG for single saves → bracket detection → merge → HDR in
  the app. Single-frame saves test the decoder and writer before the merge adds its own bugs.
- **Decoder:** LibRaw 0.22.2, **1-pass** Markesteijn (`user_qual = 2`), followed by our own
  false-colour cleanup. 3-pass isn't worth it: on average it differs from 1-pass by under one
  level in 255, and it takes twice as long.
- **License:** use LibRaw under **CDDL 1.0**, not LGPL, so the app can be sold later. That
  means three things:
  - Ship LibRaw's notice in an Acknowledgements screen.
  - Say where LibRaw's source can be found.
  - Publish any LibRaw source file we change. Prefer not changing any.
- **Output:** a demosaiced *linear* DNG, the same kind as Iridient X-Transformer, HDRMerge and
  Apple ProRAW. Editors treat it as RAW, so white balance and exposure stay adjustable. It's
  paired in Photos with a rendered JPEG, the same way RAF + JPEG pairs are saved now.

## Evidence (demosaic study)

Published comparison: https://claude.ai/artifact/STcCeHNq9CsuWgTjM525ds (private to the owner).
Code: `tools/demosaic-compare/`. CI renders Apple's crops on macOS (`.github/workflows/demosaic-compare.yml`);
`libraw_crops.py` and `compare.py` do the rest.

The test used 10 crops at 100 % from public X-T1, X-E2 and X-E2S samples (all X-Trans II), at
ISO 200–400. Results are relative to Apple with its noise reduction and sharpening off:

| Method | Fine detail | False colour | Time per frame (4-core Linux) |
|---|---|---|---|
| Markesteijn 1-pass | +18 % | +39 % | 1.6 s |
| Markesteijn 3-pass | +19 % | +37 % | 3.0 s |
| **1-pass + cleanup** | **+15 %** | **−47 %** | ~1.7 s |

- Apple's decode produced magenta and green "worm" patterns in the ISO 400 foliage.
- The app's *current* default render (Apple with sharpening) looks crunchy and shows false
  colour on twigs. That's a separate follow-up, at the end of this plan.

## Before coding: shoot test brackets

Put these on the card. They're the fixtures for every step below.

1. Tripod, in-camera **AE BKT ±1 EV** (the X-T1's maximum: 3 frames).
2. Tripod, **manual bracket** of −2 / 0 / +2 using the exposure compensation dial. The X-T1's
   built-in bracketing only reaches ±1 EV, so wide brackets are manual.
3. Handheld AE BKT ±1 EV, to test alignment.
4. A scene with motion (clouds, water, leaves in wind), to test ghosting.
5. A high-ISO frame (3200+) with foliage, to repeat the demosaic study on your own files.
6. One frame in each DR mode (DR100, DR200, DR400), to test BaselineExposure.

Copy one bracket's RAFs to the Mac as test fixtures. Keep them out of git: they're about 33 MB each.

## Step 1: LibRaw as a Swift package target

- **Source:** download `https://www.libraw.org/data/LibRaw-0.22.2.tar.gz`. The tarball is
  about 1.7 MB; github.com/LibRaw also has a 0.22.2 tag.
  - Vendor it into `Packages/FujiDropKit/Sources/CLibRaw/` unchanged, with `LICENSE.CDDL`,
    `COPYRIGHT` and a `VENDORED.md` recording the version, URL and SHA-256.
  - Drop what isn't needed: `RawSpeed*`, `GoPro`, `samples`, `bin`, `doc`, `buildfiles`,
    `object`, `lib`, the autotools and Windows files.
- **Files to compile:** every `.cpp` under `src/` **except** `postprocessing/postprocessing_ph.cpp`,
  `preprocessing/preprocessing_ph.cpp` and `write/write_ph.cpp`. Those three are placeholder
  stubs and would cause duplicate symbols. This matches `LIB_OBJECTS` in `Makefile.dist`
  (79 files).
- **Package.swift:**
  - Add the `CLibRaw` target with `publicHeadersPath: "libraw"` and `headerSearchPath(".")`.
  - Define `USE_ZLIB` and link `z` (zlib is part of the iOS SDK).
  - Leave out OpenMP; Apple's clang doesn't ship it. Use our own tiling for parallelism (below).
  - Use `-O3` in all configurations. Unoptimised Markesteijn is very slow, and Debug builds on
    the phone would make testing painful. `unsafeFlags` blocks remote package use, but this
    package is local, so it's fine. Otherwise set the optimisation per target in `project.yml`.
  - Add `-w`, since LibRaw is noisy. A C++ interop setting isn't needed if we only call the
    C API in `libraw.h` (`libraw_init`, `libraw_open_file`, `libraw_unpack`, `libraw_dcraw_process`,
    `libraw_dcraw_make_mem_image`).
- **Swift wrapper** (`Library/XTransDecoder.swift`), returning a struct with:
  - `width`, `height`;
  - linear **camera-native** RGB as `[Float]`, white-balance multipliers divided back out;
  - `camMul` (as-shot white balance), `camXYZ` (LibRaw `color.cam_xyz`, XYZ to camera);
  - black and white levels, plus EXIF: time, aperture, ISO, exposure bias, date, lens.
- **Decode parameters:**
  - `use_camera_wb = 1` (Markesteijn works best on white-balanced data);
  - `user_qual = 2`;
  - `output_color = 0` (raw camera colour);
  - `gamm[0] = gamm[1] = 1`, `no_auto_bright = 1`, `output_bps = 16`, `highlight = 0`.
- **Two LibRaw gotchas:**
  - Use one `libraw_data_t` per decode, since it isn't thread-safe.
  - Peak memory is about 200 MB per 16 MP frame during processing. Decode bracket frames one
    after another, not in parallel.
- **Checks:**
  - A unit test decodes a fixture RAF when `FUJIDROP_TEST_RAF` is set, and is skipped otherwise.
    In CI, download a raw.pixls.us X-T1 sample in a workflow step and set the variable.
  - On the iPhone, time one X-T1 decode in a Release build. The target is about 2 s or less.

## Step 2: DNG writer

Write our own minimal TIFF/DNG writer (`Library/DNGWriter.swift`), since iOS can read DNG but
not write it. HDRMerge's `DngFloatWriter` is a good reference (read it, don't copy it: GPL).
It supports two sample formats: **16-bit integer**, for single saves (step 3, built first), and
**half float**, for HDR merges (needed by step 6). Both share everything else below.

- **Layout:**
  - IFD0 holds a 1024 px 8-bit sRGB preview, `NewSubfileType = 1`.
  - A SubIFD holds the main image, `NewSubfileType = 0`.
  - An EXIF IFD carries the date, exposure and lens, copied from the source frame (the reference
    frame for merges).
- **Main image:**
  - `PhotometricInterpretation = 34892` (LinearRaw), `SamplesPerPixel = 3`.
  - Single saves: `SampleFormat = 1`, `BitsPerSample = 16`, `WhiteLevel = 65535`,
    `Compression = 8` (Deflate) with `Predictor = 2` (horizontal differencing).
  - Merges: `SampleFormat = 3`, `BitsPerSample = 16` (half float, as HDRMerge uses),
    **uncompressed**: Core Image can't decode Deflate float DNGs (see Status). `WhiteLevel` 1
    must be written for Core Image even though the spec makes it the default.
  - Tiles of 256×256. Start uncompressed and add compression once the file validates.
- **Required tags:**
  - `DNGVersion 1.4.0.0`. `DNGBackwardVersion` is 1.4.0.0 for float data, 1.1.0.0 is enough for
    16-bit integer.
  - `UniqueCameraModel "Fujifilm X-T1"`, `Make`, `Model`, `Orientation`.
  - `ColorMatrix1` = LibRaw `cam_xyz` (3×3, rows normalized as LibRaw has them), with
    `CalibrationIlluminant1 = 21` (D65; LibRaw's Adobe matrices are D65).
  - `AsShotNeutral` = 1 / camMul, normalized to green = 1.
  - Float data: scale merged values so the brightest value is 1.0 and write `WhiteLevel` 1
    (Core Image needs it; the spec says it's the default). Integer data has black at 0 (already subtracted by LibRaw) and white at 65535.
  - Set `BaselineExposure` so the frame's mid-tones render as they did at capture (for merges, the
    reference frame's), plus the DR offset. Use the existing `Brightness.stops` against the reference frame's
    embedded JPEG; that's the same logic `RAWRenderer.matchExposure` uses for DR200/DR400.
  - `DefaultCropOrigin` / `DefaultCropSize`: LibRaw's visible area, or the area all frames cover
    after alignment.
- **Validate on the Mac** before involving Photos:
  - Adobe's `dng_validate` from the DNG SDK should pass with no warnings.
  - The file should open in Lightroom (or Capture One) and in macOS Preview / Photos, with
    sensible colour and white balance. Moving the temperature slider should behave like a RAW.
  - For merges (once step 5 exists): highlight recovery should reach the detail from the darkest
    frame.

## Step 3: DNG for every save (optional format)

This comes before the merge because it runs the decoder and the writer end to end on single
frames, with no merge logic to debug alongside them.

- **Setting:** in Settings, "Save RAW as: **RAF (original)** / **DNG (sharper detail)**". It
  defaults to RAF until the owner has compared DNG saves on the phone and in a desktop editor.
- **Pipeline for each save** (in `SaveQueue.save(_:)`, on `Background.raw`):
  1. Decode the RAF with `XTransDecoder`.
  2. Apply the colour cleanup from step 5's list (`clean()`). Move it into its own file now so
     the merge can reuse it.
  3. Write the DNG. Single frames don't need float: write **16-bit integer** linear data
     (`SampleFormat = 1`, `WhiteLevel = 65535`), Deflate-compressed, to keep files near 45–55 MB.
  4. Render the **pairing JPEG from the same decoded data**, not from Apple's RAW filter.
     Otherwise the photo people see and share keeps Apple's crunchy render.
     - Convert camera colour to sRGB through `cam_xyz` and the XYZ→sRGB matrix, with the
       as-shot white balance.
     - Apply a gentle filmic tone curve, then the brightness match against the embedded JPEG
       (`Brightness.stops`, as `RAWRenderer.matchExposure` does now).
     - Tune it so the result sits close to the camera's own JPEG.
  5. `PhotoSaver.savePair(jpeg:raw:)` with the DNG as `.alternatePhoto` and
     `originalResourceChoice = .raw`.
- **Keeping the original:**
  - A Photos asset holds only one RAW, so the RAF can't ride along in the same asset.
  - Offer "Also keep RAF files" as an option: copy RAFs to a folder in the app's Documents,
    visible in Files with `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`.
  - Off by default.
- **Checks:**
  - Photos shows the pair as RAW+JPEG, and editing in Photos uses the DNG
    (`PhotoSaver.editingBase`).
  - Lightroom opens the DNG as raw. Check that Fujifilm Camera Matching profiles (Provia,
    Classic Chrome…) are still offered, and that lens corrections still apply. If the profiles
    disappear, note it in Settings next to the option.
  - At 100 %, foliage in the DNG looks like the study page's "1-pass + cleanup", not Apple's.
  - Save time on the iPhone is about 3 s or less per photo in a Release build. The save bar
    copes, since it already runs in the background.
- **Saved-state bookkeeping:** `saved.v1` maps a shot key to an asset ID. Also record the format
  each shot was saved in, so switching the setting later doesn't re-save or confuse anything.

## Step 4: bracket detection

- **Read exposure EXIF for each shot:** ExposureTime, FNumber, ISO and ExposureBiasValue.
  - Use `CGImageSource` on the cached embedded preview, but check first that the preview file
    still carries EXIF. If not, read EXIF from the RAF's JPEG before it's cached (see
    `RAFHeader.swift`).
  - Store it on `Shot`.
- **Rule:**
  - Within one moment, find runs of 3 or more frames taken within about 5 s of each other.
  - Their exposure values (EV = log2(N²/t) − log2(ISO/100)) must differ by at least ⅔ stop, and
    the scene must match (the feature-print distance already exists).
  - Fuji's maker note also has an AE-bracketing flag, but the EXIF rule covers manual brackets
    too, so use EXIF only.
- **Ranking:** brackets skip best-shot ranking, so the dark frame isn't flagged as soft and
  starred last. The moment tile gets a small "Bracket" label.
- **Unit tests:** pure functions over EV lists. Cover AE BKT, manual ±2, a non-bracket burst,
  and a bracket cut in half by the moment grouping.

## Step 5: merge

Everything happens on linear camera-native floats. For 3 frames at 16 MP that's about 200 MB per
frame in Float32. Work in horizontal strips of about 256 rows. Each strip can go to its own core
(`DispatchQueue.concurrentPerform`), which also caps memory.

1. **Normalize.** Scale each frame by its exposure relative to the reference frame (the middle
   one), using EXIF. Then refine the scale with the median ratio over pixels that are mid-tone
   in both frames, because shutter speeds aren't exact.
2. **Align.** Run `VNHomographicImageRegistrationRequest` on half-size luminance images, against
   the reference.
   - Under about 0.5 px of shift (a tripod), skip warping.
   - Otherwise warp with the homography. Core Image's perspective transform is fine on linear
     floats. Crop the result to the area every frame covers.
3. **Weight.** For each pixel:
   - Saturation: weight is 1 below 80 % of clip and falls to 0 at 95 %. Clip is per channel
     after white balance; build the mask from the max channel, dilated by 2 px.
   - Noise: weight ∝ exposure time, so brighter frames win in the shadows.
4. **Deghost.** Where a frame's normalized value differs from the reference by more than about
   0.5 stop (and the reference isn't clipped), drop that frame's weight to 0. Where the
   reference *is* clipped, take the shortest unclipped frame. Smooth the masks a little
   (Gaussian, 3–5 px) to avoid seams.
5. **Combine.** Take the weighted average.
6. **Clean up colour.** Port `clean()` from `tools/demosaic-compare/compare.py`:
   - work on log(rgb / luminance) ratios;
   - two passes of a 5×5 median filter;
   - restore the original luminance.

   Run it once on the merged result, not on each frame. vImage has no 5×5 float median, so this
   takes a small Metal kernel or a hand-written tile loop.
7. **Unit tests:** synthetic brackets made from one linear image scaled by ±1 and ±2 EV and
   clipped. The merge should reconstruct the original within 1 % and leave no seams at clip
   boundaries.

## Step 6: HDR in the app

- **Merge button:** the moment viewer shows **Merge** for brackets. Merging runs on
  `Background.raw`:
  - download the RAFs with `rawURL`;
  - decode them one after another, then merge;
  - write the DNG to a temp folder and render the pairing JPEG from the merged data, using
    Core Image on a CIImage built from the linear floats with a simple tone curve.
- **Result as a frame:** the merged result appears as a synthetic frame in the moment, labelled
  "HDR", with a key such as `camera/merge-<keys hash>`.
  - It can be compared, selected and saved like any other frame.
  - Selecting it queues it in `SaveQueue`, which needs a path for "already-rendered DNG + JPEG"
    alongside "RAF to render".
  - `PhotoSaver.savePair(jpeg:raw:)` should take the DNG as `.alternatePhoto` with
    `originalResourceChoice = .raw`. Check that Photos accepts a float linear DNG there. If it
    refuses, the fallback is 16-bit integer linear DNG.
- **Progress:** show the merge in the SaveBar or in the viewer. It should take about 6–10 s for
  three frames, plus downloads.
- **Persistence:** store merged outputs in a small cache folder, next to `RawCache`, keyed by the
  source keys. Treat them like RAF downloads: removed by pruning, rebuilt when needed.
- **Acknowledgements:** add a screen in Settings with LibRaw's CDDL notice and the source link
  (libraw.org).

## Follow-ups (not in this plan)

- Use the LibRaw-rendered JPEG for RAF saves too (step 3 builds it), which would fix the crunchy
  default render for people who keep the RAF format.
- Merge on the raw mosaic before demosaicing: one demosaic instead of three, and cleaner. Harder
  for handheld brackets.
- A Metal version of Markesteijn, if decode time is the bottleneck on the phone.
- An HDR HEIC with a gain map as a second, display-ready output.

## Session notes

- The cloud container couldn't reach github.com directly (403), but it could reach libraw.org,
  raw.pixls.us and PyPI. On the Mac none of that matters.
- raw.pixls.us sample URLs have the form `https://raw.pixls.us/download/data/Fujifilm/X-T1/<file>.RAF`.
- The X-T1 writes uncompressed RAFs (4992×3296, 14-bit, 33.8 MB), so LibRaw needs none of
  Fuji's compressed-RAF decoding.
