import FujiDropKit
import SwiftUI

struct ImportView: View {
    @StateObject private var model = ImportModel()

    var body: some View {
        NavigationStack {
            ImportContent(model: model, camera: model.camera)
                .navigationTitle("Fuji Drop")
        }
    }
}

/// Navigation values.
struct DayRef: Hashable { let id: String }
struct MomentRef: Hashable { let ids: [String] }

private struct ImportContent: View {
    @ObservedObject var model: ImportModel
    @ObservedObject var camera: CameraSession
    @State private var showSettings = false

    var body: some View {
        Group {
            if camera.catalogComplete {
                DaysList(model: model)
            } else {
                ConnectView(camera: camera) { Task { await camera.start() } }
            }
        }
        .toolbar {
            if camera.catalogComplete {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Disconnect") {
                        model.reset()
                        camera.stop()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsButton(showSettings: $showSettings)
                }
            }
        }
        .onChange(of: camera.catalogComplete) {
            if camera.catalogComplete { model.catalogReady() }
        }
        .sheet(isPresented: $showSettings) {
            TuningView(grouper: $model.grouper, cacheUsage: model.cacheUsage, clearCache: model.clearCache)
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(for: DayRef.self) { ref in
            MomentsView(model: model, dayID: ref.id, showSettings: $showSettings)
        }
        .navigationDestination(for: MomentRef.self) { ref in
            MomentDetailView(model: model, ids: ref.ids)
        }
    }
}

private struct SettingsButton: View {
    @Binding var showSettings: Bool
    var body: some View {
        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            .accessibilityLabel("Settings")
    }
}

// MARK: - Days

private struct DaysList: View {
    @ObservedObject var model: ImportModel

    var body: some View {
        List {
            Section {
                ForEach(model.days) { day in
                    NavigationLink(value: DayRef(id: day.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(day.title).font(.headline)
                                Spacer()
                                Text(day.shotIDs.count == 1 ? "1 shot" : "\(day.shotIDs.count) shots")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let span = model.dayTimeSpan(day) {
                                Text(span).font(.caption).foregroundStyle(.secondary)
                            }
                            ThumbStrip(model: model, ids: day.sampleIDs, total: day.shotIDs.count)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                }
            } footer: {
                if model.skippedNonRAW > 0 {
                    Text("\(model.skippedNonRAW) non-RAW files skipped")
                }
            }
        }
    }
}

// MARK: - Moments of one day

private struct MomentsView: View {
    @ObservedObject var model: ImportModel
    let dayID: String
    @Binding var showSettings: Bool

    var body: some View {
        List {
            Section {
                if model.dayProcessed < model.order.count {
                    ProgressView(value: Double(model.dayProcessed), total: Double(max(model.order.count, 1))) {
                        Text("Reading previews \(model.dayProcessed) of \(model.order.count)")
                            .font(.subheadline)
                    } currentValueLabel: {
                        if let left = model.previewTimeRemaining {
                            Text(left < 60 ? "About \(Int(left.rounded())) s left" : "About \(Int((left / 60).rounded())) min left")
                        }
                    }
                }
            } footer: {
                Text("\(model.moments.count) moments from \(model.order.count) shots")
            }

            ForEach(model.moments, id: \.first) { ids in
                NavigationLink(value: MomentRef(ids: ids)) {
                    MomentRow(model: model, ids: ids)
                }
            }
        }
        .navigationTitle(model.days.first { $0.id == dayID }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsButton(showSettings: $showSettings) }
        .onAppear { if model.selectedDayID != dayID { model.select(dayID: dayID) } }
    }
}

// MARK: - Connect

private struct ConnectView: View {
    @ObservedObject var camera: CameraSession
    let connect: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(status).font(.headline).multilineTextAlignment(.center)
            if camera.phase == .idle {
                Button("Connect camera", action: connect).buttonStyle(.borderedProminent)
            } else if case .failed = camera.phase {
                Button("Try again", action: connect).buttonStyle(.bordered)
            } else {
                ProgressView()
                if case .loadingCatalog = camera.phase {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(catalogProgress)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("X-T1: USB mode MTP(PTP), connect with a USB-C to micro-USB data cable, turn the camera on.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
        .onChange(of: camera.phase) {
            if case .loadingCatalog = camera.phase, catalogStart == nil { catalogStart = Date() }
            if camera.phase == .idle { catalogStart = nil }
        }
    }

    @State private var catalogStart: Date?

    /// "412 files · 6 s": a running count, since iOS can't tell us the total up front.
    private var catalogProgress: String {
        let elapsed = catalogStart.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let files = camera.files.count == 1 ? "1 file" : "\(camera.files.count) files"
        return "\(files) found · \(elapsed) s"
    }

    private var status: String {
        switch camera.phase {
        case .idle: return "Connect your camera"
        case .waitingForAuthorization: return "Waiting for permission…"
        case .searching: return "Looking for the camera…"
        case .opening(let n): return "Opening \(n)…"
        case .loadingCatalog(let n): return "Reading \(n)'s card…"
        case .ready(let n): return "\(n) ready"
        case .failed(let reason): return reason
        }
    }
}

// MARK: - Moment row

private struct MomentRow: View {
    @ObservedObject var model: ImportModel
    let ids: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(timeText).font(.subheadline.weight(.semibold))
                Spacer()
                Text(ids.count == 1 ? "1 shot" : "\(ids.count) shots")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ThumbStrip(model: model, ids: model.samples(of: ids), total: ids.count)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var timeText: String {
        let dates = ids.compactMap { model.shots[$0]?.date }
        guard let first = dates.min(), let last = dates.max() else { return ids.first ?? "" }
        let start = first.formatted(date: .omitted, time: .shortened)
        let span = last.timeIntervalSince(first)
        if span < 1 { return start }
        if span < 60 { return "\(start) · \(Int(span.rounded())) s" }
        return "\(start) – \(last.formatted(date: .omitted, time: .shortened))"
    }
}

/// A fixed row of sample thumbnails plus "+N". Not scrollable, so the whole row stays tappable.
struct ThumbStrip: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let total: Int
    var cell = CGSize(width: 64, height: 48)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in
                ShotThumbnail(shot: model.shots[id], height: cell.height, fillWidth: cell.width)
            }
            if total > ids.count {
                Text("+\(total - ids.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(height: cell.height)
    }
}

struct ShotThumbnail: View {
    let shot: ImportModel.Shot?
    let height: CGFloat
    /// When set, the image fills a fixed-width cell (cropped); otherwise it keeps its aspect ratio.
    var fillWidth: CGFloat? = nil

    var body: some View {
        let width = fillWidth ?? height * 1.5
        Group {
            if let image = shot?.thumbnail {
                if fillWidth != nil {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: width, height: height).clipped()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else if shot?.error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .frame(width: width, height: height)
            } else {
                Rectangle().fill(.quaternary).frame(width: width, height: height)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
