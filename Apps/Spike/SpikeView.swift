import UIKit
import FujiDropKit
import SwiftUI

struct SpikeView: View {
    @StateObject private var model = SpikeModel()

    var body: some View {
        NavigationStack {
            SpikeContent(model: model, camera: model.camera)
                .navigationTitle("X-T1 Spike")
        }
    }
}

/// Split out so it can observe both the model and the camera session.
private struct SpikeContent: View {
    @ObservedObject var model: SpikeModel
    @ObservedObject var camera: CameraSession
    @State private var zoomed: SpikeModel.Thumb?
    @State private var confirmSetClock = false
    @State private var copied = false

    var body: some View {
        List {
            checklist
            connectSection
            thumbnailSection
            saveSection
            clockSection
            reportSection
            logSection
        }
        .disabled(model.busy)
        .overlay { if model.busy { ProgressView().controlSize(.large) } }
        .onChange(of: camera.phase) { model.refreshConnectionCheck() }
        .onChange(of: camera.files.count) { model.refreshConnectionCheck() }
        .sheet(item: $zoomed) { ActualPixelsView(thumb: $0) }
        .confirmationDialog("Set the camera clock to this phone's time?", isPresented: $confirmSetClock, titleVisibility: .visible) {
            Button("Set camera clock") { Task { await model.testSetClock() } }
        } message: {
            Text("Writes the X-T1's date/time property over PTP. You can change it back in the camera menu.")
        }
    }

    // MARK: Sections

    private var checklist: some View {
        Section("Risks to test first") {
            ForEach(model.checks) { check in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(check.status.rawValue)  \(check.id). \(check.title)").font(.subheadline.weight(.semibold))
                    if !check.detail.isEmpty {
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            LabeledContent("Status", value: phaseText)
            LabeledContent("Contents access", value: camera.contentsAuthorization)
            LabeledContent("Control access", value: camera.controlAuthorization)
            if camera.catalogComplete {
                LabeledContent("Files / shots / pairs",
                               value: "\(camera.files.count) / \(camera.shots.count) / \(camera.shots.filter(\.isComplete).count)")
            }
            if camera.phase == .idle {
                Button("Connect to camera") { Task { await model.connect() } }
            } else {
                Button("Disconnect", role: .destructive) { camera.stop() }
            }
        } header: {
            Text("1. Connect")
        } footer: {
            Text("X-T1: set USB mode to the card-reader/PTP option (not USB RAW CONV), connect with a USB-C cable, turn the camera on.")
        }
    }

    private var thumbnailSection: some View {
        Section {
            Button("Fetch last 12 thumbnails") { Task { await model.testThumbnails() } }
                .disabled(!camera.catalogComplete)
            if !model.thumbs.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(model.thumbs) { thumb in
                            ThumbCell(thumb: thumb, selected: model.selected == thumb.basename)
                                .onTapGesture { model.selected = thumb.basename }
                                .onLongPressGesture { zoomed = thumb }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 130)
                Text("Tap to select a shot, long-press to view at 100%.").font(.caption).foregroundStyle(.secondary)
            }
            if let shot = model.selectedShot {
                Button("Download in-camera JPEG of \(shot.basename)") { Task { await model.downloadSelectedJPEG() } }
                    .disabled(shot.jpeg == nil)
            }
            if let jpeg = model.downloadedJPEG {
                Button("View \(jpeg.source) at 100% (\(jpeg.sizeText), \(jpeg.millis) ms)") { zoomed = jpeg }
            }
        } header: {
            Text("2. Thumbnail size")
        }
    }

    private var saveSection: some View {
        Section {
            Button("Download \(model.selectedShot?.basename ?? "latest pair") and save to Photos") {
                Task { await model.testSavePair() }
            }
            .disabled(!camera.catalogComplete)
        } header: {
            Text("3. RAW+JPEG to Photos")
        } footer: {
            Text("Needs a shot taken in FINE+RAW. Afterwards, open Photos and check it shows one item with a RAW+JPEG badge.")
        }
    }

    private var clockSection: some View {
        Section {
            Button("Read camera clock (PTP)") { Task { await model.testReadClock() } }
                .disabled(camera.camera == nil)
            Button("Set camera clock to phone time…") { confirmSetClock = true }
                .disabled(model.cameraClock == nil)
            if let clock = model.cameraClock {
                LabeledContent("Camera clock", value: clock)
            }
        } header: {
            Text("4. Clock over PTP")
        }
    }

    private var reportSection: some View {
        Section {
            Button(copied ? "Copied" : "Copy report") {
                UIPasteboard.general.string = model.report
                copied = true
            }
            ShareLink("Share report", item: model.report)
        } footer: {
            Text("Paste the report back into Claude Code to plan the next step.")
        }
    }

    private var logSection: some View {
        Section("Log") {
            ForEach(camera.log.reversed()) { line in
                VStack(alignment: .leading) {
                    Text(line.date.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private var phaseText: String {
        switch camera.phase {
        case .idle: return "Idle"
        case .waitingForAuthorization: return "Waiting for permission"
        case .searching: return "Searching for camera"
        case .opening(let n): return "Opening \(n)"
        case .loadingCatalog(let n): return "Loading \(n) catalog"
        case .ready(let n): return "Ready: \(n)"
        case .failed(let r): return "Failed: \(r)"
        }
    }
}

private struct ThumbCell: View {
    let thumb: SpikeModel.Thumb
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image = thumb.image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .frame(width: 120, height: 90)
            .background(Color.secondary.opacity(0.1))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(thumb.sizeText).font(.caption2.monospacedDigit())
            Text(thumb.basename).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Shows an image at one image pixel per screen pixel, the honest way to judge focus.
private struct ActualPixelsView: View {
    let thumb: SpikeModel.Thumb
    @Environment(\.displayScale) private var scale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                if let image = thumb.image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: thumb.pixelSize.width / scale, height: thumb.pixelSize.height / scale)
                }
            }
            .navigationTitle("\(thumb.source) · \(thumb.sizeText)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
