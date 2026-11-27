import FujiDropKit
import SwiftUI
import UIKit

/// One moment, full screen: the frame you're looking at, zoomable, with a filmstrip of the
/// moment's frames below. Swipe (at fit zoom) or tap the filmstrip to move between frames;
/// tap a frame's circle to select it (selecting saves it to Photos).
///
/// Compare splits the view into two panes with zoom and pan locked together, loading the
/// full-resolution RAW of both: the frame you were on, and the best-ranked other frame. The
/// filmstrip then picks the second pane; Swap exchanges them. Single-frame moments have no
/// filmstrip or compare.
struct MomentViewer: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @AppStorage("showGroupingDetails") private var showDetails = false
    /// The frame shown (the first pane in compare). Nil until you move: follows the moment's
    /// hero, which can change as scores arrive.
    @State private var current: String?
    /// The second pane while comparing; nil when not comparing.
    @State private var challenger: String?
    @State private var group = ZoomGroup()

    var body: some View {
        // Only the frames still on the card (after reconnecting, some may be gone).
        let frames = model.onCard(ids)
        if frames.isEmpty { NotOnCardView() } else { viewer(frames) }
    }

    @ViewBuilder private func viewer(_ ids: [String]) -> some View {
        let ranking = model.ranking(of: ids)
        let shown = current.flatMap { ids.contains($0) ? $0 : nil } ?? model.hero(of: ids, ranking: ranking)
        let other = challenger.flatMap { ids.contains($0) && $0 != shown ? $0 : nil }
        VStack(spacing: 0) {
            if let other {
                let sideBySide = model.aspect(shown, clamped: false) < 1
                let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
                layout {
                    pane(shown, ranking: ranking, comparing: true)
                    pane(other, ranking: ranking, comparing: true) {
                        current = other
                        challenger = shown
                    }
                }
            } else {
                pane(shown, ranking: ranking, comparing: false)
            }
            if ids.count > 1 {
                Filmstrip(model: model, ids: ids, current: shown, challenger: other) { id in
                    if other != nil {
                        if id != shown { challenger = id }
                    } else {
                        current = id
                    }
                }
            }
        }
        .background(.black)
        .navigationTitle(title(ids, shown: shown, other: other))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if ids.count > 1 {
                Button {
                    challenger = other == nil ? model.challenger(for: shown, in: ids, ranking: ranking) : nil
                } label: {
                    Label(other == nil ? "Compare" : "Done", systemImage: "square.split.1x2")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private func pane(_ id: String, ranking: ImportModel.Ranking?, comparing: Bool,
                      swap: (() -> Void)? = nil) -> some View {
        ViewerPane(
            model: model,
            shot: model.shots[id],
            flaws: ranking?.breakdowns[id]?.flaws ?? [],
            isSuggested: ranking?.suggested == id,
            details: showDetails ? details(id, ranking?.breakdowns[id]) : nil,
            group: group,
            loadsRAW: comparing,
            swap: swap,
            step: comparing ? nil : { step($0) }
        )
    }

    /// Moves to the next (+1) or previous (-1) frame after a swipe.
    private func step(_ delta: Int) {
        let frames = model.onCard(ids)
        let shown = current ?? model.hero(of: frames)
        guard let i = frames.firstIndex(of: shown), frames.indices.contains(i + delta) else { return }
        current = frames[i + delta]
    }

    private func title(_ ids: [String], shown: String, other: String?) -> String {
        let time = model.timeLabel(of: ids)
        guard ids.count > 1 else { return time }
        let position = { (id: String) in (ids.firstIndex(of: id) ?? 0) + 1 }
        if let other { return "\(position(shown)) vs \(position(other)) of \(ids.count)" }
        return "\(time) · \(position(shown)) of \(ids.count)"
    }

    /// Calibration info (Settings › Show grouping details): file name, gap and visual
    /// distance from the previous frame, and each part of the best-shot score (0–100).
    private func details(_ id: String, _ r: BestShot.Breakdown?) -> String {
        let step = model.stepFromPrevious(id)
        var parts = [id]
        if let gap = step.gap { parts.append(String(format: "+%.0f s", gap)) }
        if let d = step.distance { parts.append(String(format: "Δ %.2f", d)) }
        if let r {
            func pct(_ v: Float) -> String { String(Int((v * 100).rounded())) }
            parts.append("focus \(pct(r.sharpness))")
            if let face = r.face { parts.append("face \(pct(face))") }
            if let aesthetics = r.aesthetics { parts.append("look \(pct(aesthetics))") }
            if let eyes = r.eyeOpenness { parts.append("eyes \(pct(eyes))") }
            parts.append("= \(pct(r.total))")
        }
        return parts.joined(separator: " · ")
    }
}

/// One frame, zoomable (locked to the other pane in compare): the 1920 px preview at once,
/// then in compare the full-resolution RAW once it has downloaded and decoded.
private struct ViewerPane: View {
    @ObservedObject var model: ImportModel
    let shot: ImportModel.Shot?
    let flaws: [BestShot.Flaw]
    let isSuggested: Bool
    let details: String?
    let group: ZoomGroup
    let loadsRAW: Bool
    /// Makes this pane the first one (compare's second pane only).
    let swap: (() -> Void)?
    /// Swipe to the next/previous frame (single view only).
    let step: ((Int) -> Void)?
    @State private var image: UIImage?
    @State private var full: FullState = .loading

    private enum FullState { case loading, ready, failed }

    /// 8× in compare reaches 100 % of a 4896 px RAF in a half-width pane; the preview has
    /// nothing more to show past 4×.
    private var maxZoom: CGFloat { loadsRAW ? 8 : 4 }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, group: group, maxZoom: maxZoom, onSwipe: step)
            } else if let thumbnail = shot?.thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if let shot {
                SelectionCircle(state: model.selectionState(shot.id)) { model.toggleSelection(shot.id) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSuggested { SuggestedBadge() }
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: -14) {
                FlawTip(flaws: flaws)
                if let details { PhotoLabel(title: details) }
                if loadsRAW { rawBadge }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let swap {
                Button(action: swap) {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
        .task(id: TaskKey(id: shot?.id, preview: shot?.previewURL, loadsRAW: loadsRAW)) {
            // Keep showing the previous frame until the new one decodes (usually from the
            // in-memory cache), so the zoomable view and its viewport carry over.
            guard let shot else { image = nil; return }
            // Already decoded at full size (e.g. after swapping panes): show it straight away.
            if let raw = model.cachedRawURL(shot.id),
               let decoded = PreviewImageLoader.shared.cachedFullResolution(raw: raw) {
                image = decoded
                full = .ready
                return
            }
            full = .loading
            // Replace the previous frame even on failure (nil falls back to this shot's
            // thumbnail), so a pane never shows one frame under another's labels.
            var preview: UIImage?
            if let url = shot.previewURL {
                preview = await PreviewImageLoader.shared.load(url: url, maxPixelSize: 1920)
            }
            guard !Task.isCancelled else { return }
            image = preview
            guard loadsRAW else { return }
            // Then the real pixels (waiting out an unplug). The download continues if this
            // pane moves on to another frame, so switching back is instant.
            guard let raw = await model.rawURL(shot.id), !Task.isCancelled else {
                if !Task.isCancelled { full = .failed }
                return
            }
            let fullImage = await PreviewImageLoader.shared.loadFullResolution(raw: raw)
            guard !Task.isCancelled else { return }
            if let fullImage {
                image = fullImage
                full = .ready
            } else {
                full = .failed
            }
        }
    }

    private struct TaskKey: Equatable {
        let id: String?
        let preview: URL?
        let loadsRAW: Bool
    }

    /// Small status: loading RAW, RAW (full resolution), or RAW unavailable.
    @ViewBuilder private var rawBadge: some View {
        Group {
            switch full {
            case .loading:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("RAW")
                }
            case .ready:
                Text("RAW")
            case .failed:
                Label("RAW", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(full == .ready ? .white : .white.opacity(0.7))
        .photoCapsule()
        .accessibilityLabel(full == .ready ? "Full resolution" : full == .loading ? "Loading full resolution" : "Full resolution unavailable")
    }
}

/// Every frame of the moment, with selection and suggestion marks. Tap to show a frame (or,
/// in compare, to put it in the second pane).
private struct Filmstrip: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let current: String
    let challenger: String?
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        thumbnail(id)
                            .id(id)
                            .onTapGesture { select(id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
        .background(.black)
    }

    private func thumbnail(_ id: String) -> some View {
        let border: Color = id == current ? .white : id == challenger ? .yellow : .clear
        return PreviewImage(shot: model.shots[id])
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 2.5))
            .overlay(alignment: .topLeading) {
                let state = model.selectionState(id)
                if state != .unselected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, state == .saved ? .green : .blue)
                        .padding(3)
                }
            }
            .opacity(id == current || id == challenger ? 1 : 0.65)
            .accessibilityLabel("Frame \((ids.firstIndex(of: id) ?? 0) + 1)\(model.isSelected(id) ? ", selected" : "")")
            .accessibilityAddTraits(.isButton)
    }
}
