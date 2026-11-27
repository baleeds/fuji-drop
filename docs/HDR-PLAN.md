# HDR bracket merge: plan

Merge exposure-bracketed landscape shots into one floating-point linear DNG. The decode uses
LibRaw's Markesteijn demosaic instead of Apple's RAW engine, because X-Trans renders badly in
many editors. Written Nov 27, 2026 for a session on the local Mac, which has the X-T1, the
iPhone, Xcode and a desktop editor. Read `docs/HANDOFF.md` first for how the app works.

## Decisions already made

- **Scope:** DNG output is for HDR merges only. Ordinary saves stay RAF + JPEG, as built.
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

## Step 2: bracket detection

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

## Step 3: merge

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

## Step 4: DNG writer

Write our own minimal TIFF/DNG writer (`Library/DNGWriter.swift`), since iOS can read DNG but
not write it. HDRMerge's `DngFloatWriter` is a good reference (read it, don't copy it: GPL).

- **Layout:**
  - IFD0 holds a 1024 px 8-bit sRGB preview, `NewSubfileType = 1`.
  - A SubIFD holds the main image, `NewSubfileType = 0`.
  - An EXIF IFD carries the date, exposure and lens copied from the reference frame.
- **Main image:**
  - `PhotometricInterpretation = 34892` (LinearRaw), `SamplesPerPixel = 3`.
  - `SampleFormat = 3`, `BitsPerSample = 16` (half float, as HDRMerge uses).
  - Tiles of 256×256.
  - `Compression = 8` (Deflate) with `Predictor = 34894` (floating point, x2). Start
    uncompressed and add compression once the file validates.
- **Required tags:**
  - `DNGVersion 1.4.0.0`, `DNGBackwardVersion 1.4.0.0` (needed for float data).
  - `UniqueCameraModel "Fujifilm X-T1"`, `Make`, `Model`, `Orientation`.
  - `ColorMatrix1` = LibRaw `cam_xyz` (3×3, rows normalized as LibRaw has them), with
    `CalibrationIlluminant1 = 21` (D65; LibRaw's Adobe matrices are D65).
  - `AsShotNeutral` = 1 / camMul, normalized to green = 1.
  - `WhiteLevel` / `BlackLevel` are unused for float data. Scale the merged values so the
    brightest value is 1.0.
  - Set `BaselineExposure` so the reference frame's mid-tones render as they did at capture,
    plus the DR offset. Use the existing `Brightness.stops` against the reference frame's
    embedded JPEG; that's the same logic `RAWRenderer.matchExposure` uses for DR200/DR400.
  - `DefaultCropOrigin` / `DefaultCropSize` after alignment.
- **Validate on the Mac** before involving Photos:
  - Adobe's `dng_validate` from the DNG SDK should pass with no warnings.
  - The file should open in Lightroom (or Capture One) and in macOS Preview / Photos, with
    sensible colour and white balance. Moving the temperature slider should behave like a RAW.
  - Highlight recovery should reach the detail from the darkest frame.

## Step 5: app integration

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

- Use the LibRaw path for *every* save's JPEG, which would fix the crunchy default render. It
  could also optionally save the converted DNG instead of the RAF for all saves, which was
  considered earlier and deferred.
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
