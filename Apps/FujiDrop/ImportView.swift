import FujiDropKit
import SwiftUI

struct ImportView: View {
    @StateObject private var model = ImportModel()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ImportContent(model: model, camera: model.camera)
        }
        .reconnectOverlay(model)
        // Below every screen in the stack (and above the reconnect overlay), so saving stays
        // visible while you browse and says when it's waiting for the camera.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SaveBar(saves: model.saves, waitingForCamera: model.connection == .reconnecting)
        }
        // Session ended or a different camera: nothing pushed belongs to it any more.
        .onChange(of: model.cameraID) { path = NavigationPath() }
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
        let inSession = model.connection != .none
        Group {
            if inSession {
                DaysFeed(model: model)
            } else {
                ConnectView(camera: camera) { Task { await camera.start() } }
            }
        }
        .navigationTitle(inSession ? "Fuji Drop" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSession {
                ToolbarItem(placement: .topBarTrailing) { SettingsButton(showSettings: $showSettings) }
            }
        }
        .sheet(isPresented: $showSettings) {
            TuningView(grouper: $model.grouper, cacheUsage: model.cacheUsage, log: camera.log,
                       clearCache: model.clearCache) {
                showSettings = false
                model.endSession()
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(for: DayRef.self) { ref in
            MomentsFeed(model: model, dayID: ref.id, showSettings: $showSettings)
        }
        .navigationDestination(for: MomentRef.self) { ref in
            MomentViewer(model: model, ids: ref.ids)
        }
    }
}

struct SettingsButton: View {
    @Binding var showSettings: Bool
    var body: some View {
        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
            .accessibilityLabel("Settings")
    }
}

/// Small time + frame-count label laid over a photo.
struct PhotoLabel: View {
    let title: String
    var count: Int = 1

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if count > 1 {
                Image(systemName: "square.stack").imageScale(.small)
                Text("\(count)")
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .photoCapsule()
    }
}

extension View {
    /// The dark capsule used for every label laid over a photo.
    func photoCapsule() -> some View {
        foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(10)
    }
}

/// The selection control in a photo's top-left corner: an empty ring, blue once selected
/// (saving), green once it's in Photos. `count` above 1 shows how many frames of a moment
/// are selected.
struct SelectionCircle: View {
    enum Kind { case unselected, selected, saved }

    let state: Kind
    var count = 0
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle().fill(fill)
                Circle().strokeBorder(.white, lineWidth: 2)
                if state != .unselected {
                    if count > 1 {
                        Text("\(count)").font(.caption.weight(.bold).monospacedDigit())
                    } else {
                        Image(systemName: "checkmark").font(.caption.weight(.bold))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(state == .unselected ? [] : .isSelected)
    }

    private var fill: Color {
        switch state {
        case .unselected: return .black.opacity(0.25)
        case .selected: return .blue
        case .saved: return .green
        }
    }

    private var label: String {
        switch state {
        case .unselected: return "Select"
        case .selected: return count > 1 ? "\(count) selected, saving" : "Selected, saving"
        case .saved: return count > 1 ? "\(count) selected, in Photos" : "Selected, in Photos"
        }
    }
}

/// Why a frame is probably not the best, e.g. "Soft focus · Eyes closed".
struct FlawTip: View {
    let flaws: [BestShot.Flaw]

    var body: some View {
        if !flaws.isEmpty {
            Label(flaws.map(\.title).joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .photoCapsule()
        }
    }
}

/// Marks the suggested frame of a moment (until the owner picks one), or the favourite in compare.
struct SuggestedBadge: View {
    var label = "Suggested"

    var body: some View {
        Image(systemName: "star.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.yellow)
            .padding(7)
            .background(.black.opacity(0.45), in: Circle())
            .padding(10)
            .accessibilityLabel(label)
    }
}

// MARK: - Days

private struct DaysFeed: View {
    @ObservedObject var model: ImportModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.days) { day in
                    NavigationLink(value: DayRef(id: day.id)) {
                        DayCollage(model: model, day: day)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .onAppear { model.loadDaySamples() }
    }
}

/// One large photo and two small ones, spread across the day, with the date over the photo.
private struct DayCollage: View {
    @ObservedObject var model: ImportModel
    let day: ImportModel.Day

    var body: some View {
        let samples = day.sampleIDs
        GeometryReader { geo in
            HStack(spacing: 2) {
                PreviewImage(shot: samples.first.flatMap { model.shots[$0] })
                    .frame(width: samples.count > 1 ? geo.size.width * 2 / 3 - 1 : geo.size.width)
                if samples.count > 1 {
                    VStack(spacing: 2) {
                        ForEach(samples.dropFirst(), id: \.self) { id in
                            PreviewImage(shot: model.shots[id])
                        }
                    }
                    .frame(width: geo.size.width / 3 - 1)
                }
            }
        }
        .frame(height: 280)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 90)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption)
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let shots = day.shotIDs.count == 1 ? "1 shot" : "\(day.shotIDs.count) shots"
        let selected = model.selected(in: day.shotIDs).count
        return [shots, selected > 0 ? "\(selected) selected" : nil, model.dayTimeSpan(day)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Moments of one day

private struct MomentsFeed: View {
    @ObservedObject var model: ImportModel
    let dayID: String
    @Binding var showSettings: Bool

    var body: some View {
        if model.hasDay(dayID) { feed } else { NotOnCardView() }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(model.moments, id: \.first) { ids in
                    NavigationLink(value: MomentRef(ids: ids)) {
                        MomentTile(model: model, ids: ids)
                    }
                    .buttonStyle(.plain)
                    // Outside the link, so tapping the circle selects instead of opening.
                    .overlay(alignment: .topLeading) {
                        let hero = model.hero(of: ids)
                        SelectionCircle(state: model.selectionState(hero),
                                        count: model.selected(in: ids).count) {
                            model.toggleSelection(hero)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.dayProcessed < model.order.count { progress }
        }
        .navigationTitle(model.days.first { $0.id == dayID }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            let selected = model.selected(in: model.order).count
            if selected > 0 {
                Text("\(selected) selected").font(.subheadline).foregroundStyle(.secondary)
            }
            SettingsButton(showSettings: $showSettings)
        }
        .onAppear { if model.selectedDayID != dayID { model.select(dayID: dayID) } }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(model.dayProcessed), total: Double(max(model.order.count, 1)))
            Text(progressText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var progressText: String {
        var text = "Reading previews \(model.dayProcessed) of \(model.order.count)"
        if let left = model.previewTimeRemaining {
            text += left < 60 ? " · about \(Int(left.rounded())) s" : " · about \(Int((left / 60).rounded())) min"
        }
        return text
    }
}

/// A moment as one full-width photo: its first selected frame, else the suggestion (the
/// middle frame until scored). The selection circle is laid over it by the feed.
private struct MomentTile: View {
    @ObservedObject var model: ImportModel
    let ids: [String]

    var body: some View {
        let hero = model.hero(of: ids)
        PreviewImage(shot: model.shots[hero])
            .aspectRatio(model.aspect(hero), contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomLeading) {
                PhotoLabel(title: model.timeLabel(of: ids), count: ids.count)
            }
            .contentShape(Rectangle())
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

    private var status: String { camera.phase.statusText }
}

