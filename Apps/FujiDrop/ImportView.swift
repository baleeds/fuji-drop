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

/// Identifies a moment for navigation by its shot IDs.
struct MomentRef: Hashable {
    let ids: [String]
}

private struct ImportContent: View {
    @ObservedObject var model: ImportModel
    @ObservedObject var camera: CameraSession
    @State private var showTuning = false

    var body: some View {
        Group {
            if camera.catalogComplete {
                momentsList
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
                    Button { showTuning = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Grouping settings")
                }
            }
        }
        .onChange(of: camera.catalogComplete) {
            if camera.catalogComplete { model.catalogReady() }
        }
        .sheet(isPresented: $showTuning) {
            TuningView(grouper: $model.grouper, cacheUsage: model.cacheUsage, clearCache: model.clearCache)
                .presentationDetents([.medium, .large])
        }
        .navigationDestination(for: MomentRef.self) { ref in
            MomentDetailView(model: model, ids: ref.ids)
        }
    }

    private var momentsList: some View {
        List {
            Section {
                if !model.days.isEmpty {
                    Picker("Day", selection: Binding(
                        get: { model.selectedDayID ?? "" },
                        set: { model.select(dayID: $0) }
                    )) {
                        ForEach(model.days) { Text($0.title).tag($0.id) }
                    }
                }
                if model.previewsLoaded < model.order.count {
                    ProgressView(value: Double(model.previewsLoaded), total: Double(max(model.order.count, 1))) {
                        Text("Reading previews \(model.previewsLoaded) of \(model.order.count)")
                            .font(.subheadline)
                    } currentValueLabel: {
                        if let left = model.previewTimeRemaining {
                            Text(left < 60 ? "About \(Int(left.rounded())) s left" : "About \(Int((left / 60).rounded())) min left")
                        }
                    }
                }
            } footer: {
                Text("\(model.moments.count) moments from \(model.order.count) shots"
                     + (model.skippedNonRAW > 0 ? " · \(model.skippedNonRAW) non-RAW files skipped" : ""))
            }

            ForEach(model.moments, id: \.first) { ids in
                NavigationLink(value: MomentRef(ids: ids)) {
                    MomentRow(model: model, ids: ids)
                }
            }
        }
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
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(ids.prefix(12), id: \.self) { id in
                        ShotThumbnail(shot: model.shots[id], height: 56)
                    }
                    if ids.count > 12 {
                        Text("+\(ids.count - 12)").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
                    }
                }
            }
            .frame(height: 56)
        }
        .padding(.vertical, 4)
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

struct ShotThumbnail: View {
    let shot: ImportModel.Shot?
    let height: CGFloat

    var body: some View {
        Group {
            if let image = shot?.thumbnail {
                Image(uiImage: image).resizable().scaledToFit()
            } else if shot?.error != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .frame(width: height * 1.5)
            } else {
                Rectangle().fill(.quaternary).frame(width: height * 1.5)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
