# X-T1 Best-Shot App: What We Can Leverage

Nov 26, 2026 · @Benjamin Leeds

## Bottom line

Almost every hard problem in the day-1 app already has an Apple framework or open-source answer. The genuinely custom work is the compare-and-pick screen and how you blend the quality scores.

- **Solved by Apple:** USB transfer (ImageCaptureCore), X-T1 RAW decode (Core Image), similarity grouping, face quality and aesthetics scoring (Vision), sharpness (Metal), RAW+JPEG saving (PhotoKit), background finishing (BackgroundTasks).
- **Solved in open source:** Fuji's Wi-Fi protocol (libfuji), burst merging for later (Burst Photo, HDRMerge).
- **Yours to build:** moment grouping thresholds, a composite "best shot" score, the synced-zoom compare UI, and the share flow.

Lightroom for iPhone already does direct camera import and Assisted Culling, but it needs a subscription. Decision: build our own, with a faster single-purpose flow that ends in Apple Photos. The build brief is in Claude Code handoff.

## Transfer: camera to phone

Use Apple's ImageCaptureCore over USB-C for day 1; it's the same path shipping apps use, and iOS offers no raw USB access anyway.

- **What it gives you:** device discovery (`ICDeviceBrowser`), the camera's file catalog, per-file thumbnails and metadata, and file download. A shipping Sony transfer app ([CamLink](https://github.com/roriloty/camlink-app/releases)) does exactly this on iPhone and notes iOS asks the user to allow camera control.
- **Vendor commands are uncertain on iOS.** The API to send raw PTP commands exists on iOS 13+, but [a 2020 report](https://developer.apple.com/forums/thread/656878) shows iOS refusing it with a not-authorized error while the same code worked on macOS. Treat camera clock sync (a PTP property write) as unconfirmed until tested.
- **Known rough edges:** a [developer report](https://developer.apple.com/forums/thread/763676) shows an empty file list from a Sony body while other apps worked, and an [iOS 26.1 beta regression](https://developer.apple.com/forums/tags/photos-and-imaging?page=3) left authorization stuck at not-determined. Build the permission flow defensively.
- **Camera setting:** the X-T1 must be in its USB card-reader/PTP connection mode, not the RAW-conversion mode. Verify in the menu.

**Wi-Fi later:** [libfuji](https://github.com/petabyt/libfuji) implements Fuji's proprietary protocol, including the legacy Camera Remote mode the X-T1 uses and PC AutoSave. It's C, callable from Swift, but untested on the X-T1 and GPL-licensed (fine for a personal sideloaded app).

## Previews and RAW decode

Cull on previews, decode RAW only for the pick; Apple decodes X-T1 RAFs natively, so no third-party RAW library is needed.

- **Native support:** the X-T1 is on Apple's [RAW support list for iOS 27](https://support.apple.com/127493) and has been since iOS 10, so `CIRAWFilter` decodes it with exposure, white balance, shadow boost, and noise reduction controls.
- **Previews are the fast path.** One culling-app spec measured full `CIRAWFilter` decode at roughly 3 seconds on first call and 50 to 200 ms after, with the embedded-preview path [10 to 100 times faster](https://forge.blacksky.community/dunkirk.sh/cull/raw/main/SPEC.md). Pull camera thumbnails or the RAF's embedded JPEG, downscale, and score those.
- **Over the cable, previews can come from the camera.** Lightroom users found Fuji RAW thumbnails [render when the camera is connected directly](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-discussions/p-lightroom-mobile-import-screen-does-not-display-my-image-thumbs-like-lr-desktop/m-p/15404478/highlight/true) but not from a card reader. That supports the camera-cable route.
- **Open question:** how large the X-T1's thumbnails over PTP are. If they're too small for a sharpness check, download the in-camera JPEG for scoring, which is still far smaller than the RAF.

## Grouping shots into moments

Cluster by capture time first, then split or merge using Vision feature prints; Lightroom's Auto Stack uses the same [time plus visual similarity](https://helpx.adobe.com/dk/lightroom-classic/desktop/organize-photos-in-lightroom-classic/assisted-culling.html) idea.

- **Feature prints:** `VNGenerateImageFeaturePrintRequest` produces a vector per image, and `computeDistance` gives a distance where [smaller means more similar](https://fritz.ai/?p=8864). It's on-device and available since iOS 13.
- **Thresholds are yours to tune.** Distances have no fixed scale; one developer saw about 26 between two different cat photos and asked [what counts as similar](https://medium.com/@MWM.io/apples-vision-framework-exploring-advanced-image-similarity-techniques-f7bb7d008763). Calibrate on your own shots.
- **Test on a device.** The simulator gives [wrong distances](https://developer.apple.com/forums/thread/721760) unless forced to CPU, and request revisions must match or [comparisons fail](https://developer.apple.com/forums/tags/visionkit?page=6). Store the revision with each print.
- **Suggested rule:** frames within a few seconds are one moment unless their distance is large; frames minutes apart join a moment only if very close. Always allow manual split and merge.

## Picking the best shot

Three ready-made signals cover sharpness, faces, and overall appeal; combine them into one score per frame and rank within each moment.

| Signal | API | Measures | Caveat |
| --- | --- | --- | --- |
| Sharpness | [MPSImageLaplacian](https://developer.apple.com/tutorials/data/documentation/metalperformanceshaders/mpsimagelaplacian.md) + mean/variance | Edge detail; roughly 1 to 5 ms per image on the GPU per [one spec](https://forge.blacksky.community/dunkirk.sh/cull/raw/main/SPEC.md) | Rewards busy backgrounds and misreads plain scenes like sky; run it on the subject crop |
| Face quality | [VNDetectFaceCaptureQualityRequest](https://developer.apple.com/documentation/vision/selecting-a-selfie-based-on-capture-quality.md) (iOS 13+) | 0 to 1 score for lighting, blur, occlusion, expression, pose, focus | Faces only; meant for ranking captures of the same person, which is exactly a moment |
| Overall appeal | [CalculateImageAestheticsScoresRequest](https://pub.dev/documentation/apple_vision_aesthetics/latest/) (iOS 18+) | -1 to 1 score; blur and exposure pull it down; flags utility shots | Device only, [not the simulator](https://developer.apple.com/forums/thread/757286) |

Suggested recipe: if faces exist, lead with face quality and sharpness on the face crops; otherwise use sharpness on the salient region plus the aesthetics score. Apple's own [sharpest-image sample](https://github.com/artemnovichkov/wwdc20-samplecode/blob/master/FindingTheSharpestImageInASequenceOfCapturedImages) shows the Laplacian variance method with vImage if you'd rather stay on the CPU.

## What we actually build: the compare screen

No framework provides this, and it's where the app earns its keep: judging sharpness the phone screen hides.

- **Synced loupe:** two or more variants, pan and zoom locked together, one tap to jump to 100% on the face or subject.
- **Focus overlay:** tint the Laplacian response over the subject so the sharp frame is obvious at a glance.
- **Suggested pick:** badge the top-scored frame per moment, with a short reason (sharpest eyes, eyes open) like Lightroom's [culling info](https://helpx.adobe.com/lightroom-cc/using/assisted-culling.html). One tap accepts or overrides.
- **Day flow:** moments in time order; swipe through, accept a pick each, and only then fetch the RAF for the chosen frames.

## Saving to Photos

PhotoKit supports exactly the RAW+JPEG asset we want, and iOS 27 adds a switch to make the RAW the editing base.

- **Pairing:** one `PHAssetCreationRequest` with the JPEG as `.photo` and the RAF as `.alternatePhoto`. Apple describes this as the shape of [photos imported from an external camera](https://developer.apple.com/documentation/photos/phassetresourcetype/alternatephoto.md).
- **New in iOS 27:** `originalResourceChoice` on the creation request [selects RAW or JPEG](https://developer.apple.com/documentation/photos/phassetcreationrequest/originalresourcechoice.md) as the unadjusted base for RAW+JPEG assets. That's how a quick Photos edit starts from the RAF.
- **Gotcha:** developers found the pair saves reliably when the [RAW is added from a file URL](https://developer.apple.com/forums/thread/18075), not from in-memory data. Write the RAF to a temp file first.
- **Location:** set `location` on the creation request. To borrow it, fetch your iPhone photos near the X-T1 timestamp and copy the closest one's coordinates. A [forum report](https://developer.apple.com/forums/thread/688434) notes this location lives in the Photos record, not inside the RAW file, so it won't travel with an exported RAF.

## Background work and iOS limits

Plan for the USB transfer to happen with the app on screen; only the processing after it can reliably continue in the background.

- **USB stops when you leave.** CamLink reports iOS [pauses USB transfer](https://github.com/roriloty/camlink-app/releases) when the app isn't on screen or the phone locks. Keep the cable phase short by fetching previews first and only the picked RAFs.
- **Processing can continue.** iOS 26's [`BGContinuedProcessingTask`](https://developer.apple.com/tutorials/data/documentation/backgroundtasks/bgcontinuedprocessingtask.md) lets a user-started job keep running after the app is backgrounded, with system progress UI.
- **But it's best-effort.** Apple's guidance is to treat it as a bonus: if the task fails to start or expires, [save state and resume later](https://developer.apple.com/forums/thread/802073). Developers also report ML-heavy work running [4 to 5 times slower](https://developer.apple.com/forums/thread/807957) in the background.
- **Use one task with child progress** for a batch, rather than one task per photo, [per Apple's DTS](https://developer.apple.com/forums/thread/796944).

## Sharing to Instagram

For day 1, save to Photos and hand off through the system share sheet; Meta's own integration adds little for feed posts.

- **Feed:** Meta documents passing a photo to Instagram's [feed composer](https://developers.facebook.com/documentation/instagram-platform/sharing-to-feed) on iOS through Document Interaction or universal links. No app registration is required for that path.
- **Stories and Reels** use a custom URL scheme and pasteboard, and have required a [Meta App ID since January 2023](https://developers.facebook.com/documentation/instagram-platform/sharing-to-stories). Skip unless you want one-tap story posting.
- **In practice** you'll likely edit in Photos before posting, so the cleanest handoff may just be "Saved to Photos" plus an Open Instagram button.

## Later: burst merge prior art

Two open-source projects already merge RAW bursts into DNGs, but both treat Fuji's X-Trans sensor as a second-class case.

- **[Burst Photo (hdr-plus-swift)](https://github-three-lyart.vercel.app/martin-marek/hdr-plus-swift):** a Swift/Metal macOS take on Google's HDR+, with motion-robust merging and bracketed bursts. Its newer features are Bayer-only, and X-Trans support is still [limited](https://discuss.pixls.us/t/burst-image-denoising-showcase/39054), with the maintainers asking X-Trans owners for test photos.
- **[HDRMerge](https://www.github.com/jcelaya/hdrmerge):** merges bracketed raws into a floating-point DNG, with X-Trans support marked experimental. It's a good reference for writing HDR DNGs.
- **Implication:** for the X-T1, the practical route is still demosaic first (via `CIRAWFilter`), then align and merge in linear RGB. Both projects are useful mainly as algorithm references.

## Leverage vs. build at a glance

| Problem | Leverage | You build | Confidence it works on X-T1 |
| --- | --- | --- | --- |
| USB transfer | ImageCaptureCore | Permission flow, incremental import | Medium: untested with this body |
| Clock sync | PTP property write | Nothing else | Low: iOS may block vendor commands |
| Previews | Camera thumbnails, embedded JPEG | Size check | Medium |
| RAW decode | CIRAWFilter | Default render settings | High: X-T1 is on Apple's list |
| Moments | Vision feature prints | Thresholds, split/merge UI | High |
| Best-shot score | Laplacian (MPS), face quality, aesthetics | Score blend | High |
| Compare UI | None | All of it | Not applicable |
| Save to Photos | PhotoKit RAW+JPEG, iOS 27 RAW base | Location borrowing | High |
| Background finish | BGContinuedProcessingTask | Resumable state | Medium: best-effort |
| Instagram | Share sheet, feed handoff | Button | High |
| Wi-Fi (later) | libfuji | Swift wrapper | Low: untested, GPL |
| Merge (later) | Burst Photo, HDRMerge as references | X-Trans path | Low to medium |

## Risks to test first

A one-evening spike with the camera on the cable answers the four questions everything else depends on.

- [ ] ImageCaptureCore sees the X-T1 on the iPhone 16 and lists its files
- [ ] Thumbnail size over PTP is large enough to judge sharpness
- [ ] A RAF plus JPEG saves to Photos as one paired asset
- [ ] Reading or setting the camera clock over PTP works, or fails with not-authorized

If the first item fails, fall back to an SD card reader through the Files picker, which also works on iOS; the rest of the plan is unchanged.

## Sources

- [Apple: RAW formats supported by iOS 27](https://support.apple.com/127493)
- [Apple: requestSendPTPCommand](<https://developer.apple.com/tutorials/data/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:).md>)
- [Apple forums: PTP commands on iOS not authorized](https://developer.apple.com/forums/thread/656878)
- [Apple forums: ImageCaptureCore empty file list](https://developer.apple.com/forums/thread/763676)
- [CamLink releases (ImageCaptureCore on iPhone)](https://github.com/roriloty/camlink-app/releases)
- [libfuji](https://github.com/petabyt/libfuji)
- [Cull app spec: preview vs. RAW timing, blur pipeline](https://forge.blacksky.community/dunkirk.sh/cull/raw/main/SPEC.md)
- [Apple: selecting a selfie by capture quality](https://developer.apple.com/documentation/vision/selecting-a-selfie-based-on-capture-quality.md)
- [apple\_vision\_aesthetics (aesthetics score details)](https://pub.dev/documentation/apple_vision_aesthetics/latest/)
- [Apple: MPSImageLaplacian](https://developer.apple.com/tutorials/data/documentation/metalperformanceshaders/mpsimagelaplacian.md)
- [Apple: PHAssetResourceType.alternatePhoto](https://developer.apple.com/documentation/photos/phassetresourcetype/alternatephoto.md)
- [Apple: originalResourceChoice](https://developer.apple.com/documentation/photos/phassetcreationrequest/originalresourcechoice.md)
- [Apple: BGContinuedProcessingTask](https://developer.apple.com/tutorials/data/documentation/backgroundtasks/bgcontinuedprocessingtask.md)
- [Meta: Instagram sharing to feed](https://developers.facebook.com/documentation/instagram-platform/sharing-to-feed)
- [Adobe: Lightroom iOS import from camera](https://helpx.adobe.com/lightroom/mobile/add-and-capture-photos/add-and-import-photos/import-photos-from-card-or-cameras.html)
- [Adobe: Assisted Culling](https://helpx.adobe.com/lightroom-cc/using/assisted-culling.html)
- [Burst Photo (hdr-plus-swift)](https://github-three-lyart.vercel.app/martin-marek/hdr-plus-swift)
- [HDRMerge](https://www.github.com/jcelaya/hdrmerge)
