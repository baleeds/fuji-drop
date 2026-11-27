# Fuji Drop

An iPhone app that pulls a day's shots off a Fujifilm X-T1 over USB-C, groups them into
moments, suggests the best frame in each, lets you compare and pick, and saves the picks to
Apple Photos as RAW+JPEG. Background and API research: [docs/leverage-research.md](docs/leverage-research.md).

## Layout

| Path | What |
| --- | --- |
| `project.yml` | XcodeGen spec (source of truth for the Xcode project) |
| `Apps/Spike` | **X-T1 Spike** app: runs the four risk checks on a real camera |
| `Apps/FujiDrop` | Main app shell (placeholder screens for the day flow) |
| `Packages/FujiDropKit` | Shared code: ImageCaptureCore session, PTP helpers, RAF/JPEG pairing, moment grouping, Photos saving |
| `Config/Signing.xcconfig` | Team / bundle ID; override in `Config/Local.xcconfig` |

## Setup

Needs Xcode 26+ and an iPhone on iOS 26+.

```sh
brew install xcodegen
cat > Config/Local.xcconfig <<'EOF'
DEVELOPMENT_TEAM = YOURTEAMID
BUNDLE_ID_PREFIX = com.yourname
EOF
xcodegen generate
open FujiDrop.xcodeproj
```

Run the package's unit tests (pure logic, runs on the Mac):

```sh
cd Packages/FujiDropKit && swift test
```

## Running the spike

1. On the X-T1: **Set-up › Connection setting › PC connection mode** (wording varies by firmware)
   → choose the card-reader / USB mode, **not** USB RAW CONV./BACKUP RESTORE.
   Set image quality to **FINE+RAW** and take a few shots, including a short burst.
2. Build the **FujiDropSpike** scheme to your iPhone (camera access doesn't work in the Simulator).
3. Plug the camera in with a USB-C cable, turn it on, tap **Connect to camera**, and allow access.
4. Work down the sections:
   - **1. Connect:** passes when the catalog loads with files. An empty list is a known iOS issue
     with some bodies; note it in the report.
   - **2. Thumbnail size:** fetches the last 12 thumbnails plus one RAF thumbnail and reports
     pixel sizes. Long-press one to view at 100%. Also try "Download in-camera JPEG" to time the
     fallback.
   - **3. RAW+JPEG to Photos:** downloads the selected pair, saves it as one asset, and lists the
     resources Photos stored. Pass = `photo` + `alternatePhoto`. Check Photos shows a RAW+JPEG badge.
   - **4. Clock over PTP:** sends GetDeviceInfo, then reads DateTime (0x5011). If iOS refuses
     pass-through, that answers the question. "Set" writes the phone's time to the camera, after
     asking first.
5. Tap **Copy report** and paste it back into the Claude Code session.

If check 1 fails outright, the fallback is an SD card reader through the Files picker; the rest
of the plan is unchanged.

## Not verified yet

This code was written without a Mac, so **none of it has been compiled**. Expect small
fixes when you first build. API names most likely to need adjusting:

- `ICDeviceBrowser.browsedDeviceTypeMask` mask construction
- `ICCameraDevice.requestSendPTPCommand(_:outData:completion:)`: the order of the two `Data`
  arguments in the completion (the code detects which one is the response container either way)
- Whether the PTP command needs our transaction ID or ImageCaptureCore rewrites it
- iOS 27 `originalResourceChoice` is left as a TODO in `PhotoSaver` until checked against the SDK
