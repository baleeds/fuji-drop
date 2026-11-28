import FujiDropKit
import SwiftUI
import UIKit

/// One moment, full screen: the frame you're looking at, zoomable, with a filmstrip of the
/// moment's frames below. Swipe (at fit zoom) or tap the filmstrip to move between frames;
/// tap a frame's circle to select it (selecting saves it to Photos).
///
/// Compare stacks two panes with zoom and pan locked together, loading the
/// full-resolution RAW of both: the frame you were on, and the best-ranked other frame. The
/// filmstrip marks which pane each frame is in and picks the second pane; Swap exchanges
/// them. Single-frame moments have no
/// filmstrip or compare.
///
/// A moment with an exposure bracket offers Merge: the bracket's RAFs are merged into an HDR
/// frame (a linear DNG), which then joins the moment and is shown.
struct MomentViewer: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @AppStorage("showGroupingDetails") private var showDetails = false
    /// Face close-ups in place of the filmstrip.
    @AppStorage("showFaces") private var showFaces = false
    /// The frame shown (the first pane in compare). Nil until you move: follows the moment's
    /// hero, which can change as scores arrive.
    @State private var current: String?
    /// The second pane while comparing; nil when not comparing.
    @State private var challenger: String?
    @State private var group = ZoomGroup()
    /// The HDR frame to show once the merge started here finishes.
    @State private var awaitedMerge: String?
    /// The bracket shown in the Merge sheet before merging.
    @State private var confirming: BracketRef?

    var body: some View {
        // Only the frames still on the card (after reconnecting, some may be gone), as the
        // moment is now (a merge adds its HDR frame).
        let frames = model.onCard(model.liveMoment(ids))
        Group {
            if frames.isEmpty { NotOnCardView() } else { viewer(frames) }
        }
        // Score this moment's frames first: the suggestion and the faces depend on it.
        .task(id: ids) { model.prioritizeScoring(ids) }
        .onDisappear { model.endScoringPriority(ids) }
    }

    @ViewBuilder private func viewer(_ ids: [String]) -> some View {
        let ranking = model.ranking(of: ids)
        let shown = current.flatMap { ids.contains($0) ? $0 : nil } ?? model.hero(of: ids, ranking: ranking)
        let other = challenger.flatMap { ids.contains($0) && $0 != shown ? $0 : nil }
        VStack(spacing: 0) {
            if let other {
                // Always stacked: on a phone, half the height at full width is larger than
                // half the width even for portrait frames, and much larger once zoomed in.
                VStack(spacing: 2) {
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
                let select = { (id: String) in self.select(id, shown: shown, comparing: other != nil) }
                if showFaces {
                    FacesPanel(model: model, ids: ids, current: shown, challenger: other,
                               suggested: ranking?.suggested, select: select)
                } else {
                    Filmstrip(model: model, ids: ids, current: shown, challenger: other,
                              suggested: ranking?.suggested, select: select)
                }
            }
        }
        .overlay(alignment: .top) { mergeStatus(bracket(ids, shown: shown)) }
        .onChange(of: ids) {
            if let awaitedMerge, ids.contains(awaitedMerge) {
                current = awaitedMerge
                challenger = nil
                self.awaitedMerge = nil
            }
        }
        .sheet(item: $confirming) { ref in
            MergeSheet(model: model, ids: ref.ids) {
                confirming = nil
                startMerge(ref.ids)
            }
            .presentationDetents([.height(330)])
        }
        .background(.black)
        .navigationTitle(title(ids, shown: shown, other: other))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if model.fujiCamera.supportsXTransProcessing,
               let bracket = bracket(ids, shown: shown), !model.isMerged(bracket),
               model.merging[model.mergeKey(bracket)] == nil {
                Button {
                    confirming = BracketRef(ids: bracket)
                } label: {
                    Label("Merge", systemImage: "square.3.layers.3d")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityHint("Shows the exposure bracket to merge into one HDR photo")
            }
            if ids.count > 1 {
                Button {
                    showFaces.toggle()
                } label: {
                    Image(systemName: showFaces ? "person.crop.square.fill" : "person.crop.square")
                }
                .accessibilityLabel(showFaces ? "Show filmstrip" : "Show faces")
                .accessibilityHint("Lines up each person's face across the moment's frames")
                Button {
                    challenger = other == nil ? model.challenger(for: shown, in: ids, ranking: ranking) : nil
                } label: {
                    Label(other == nil ? "Compare" : "Done", systemImage: "square.split.1x2")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    /// A tap in the filmstrip or faces panel: show the frame, or in compare put it in the
    /// second pane.
    private func select(_ id: String, shown: String, comparing: Bool) {
        if !comparing {
            current = id
        } else if id != shown {
            challenger = id
        }
    }

    /// The bracket Merge acts on: the shown frame's, else the moment's first one not merged.
    private func bracket(_ ids: [String], shown: String) -> [String]? {
        if let b = model.bracket(of: shown) { return b }
        return ids.lazy.compactMap { model.bracket(of: $0) }.first { !model.isMerged($0) }
    }

    /// Merges the bracket and shows its HDR frame once it's done.
    private func startMerge(_ bracket: [String]) {
        awaitedMerge = model.mergedID(bracket)
        model.merge(bracket)
    }

    /// Merge progress or failure (with Retry) over the top of the viewer.
    @ViewBuilder private func mergeStatus(_ bracket: [String]?) -> some View {
        if let bracket {
            switch model.merging[model.mergeKey(bracket)] {
            case .running(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("HDR · \(step)")
                }
                .font(.caption.weight(.semibold))
                .photoCapsule()
            case .failed(let reason):
                HStack(spacing: 8) {
                    Label("Merge failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    Button("Retry") { startMerge(bracket) }
                    .bold()
                }
                .font(.caption.weight(.semibold))
                .photoCapsule()
            case nil:
                EmptyView()
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
        let frames = model.onCard(model.liveMoment(ids))
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

    /// The photo's size at fit zoom within `space`.
    private func fittedSize(in space: CGSize) -> CGSize {
        guard let size = image?.size ?? shot?.thumbnail?.size, size.width > 0, size.height > 0 else { return space }
        let scale = min(space.width / size.width, space.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var photo: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, group: group, maxZoom: maxZoom, onSwipe: step)
            } else if let thumbnail = shot?.thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            }
        }
        .dimmedIfMergeMissing(shot)
        .clipped()
        .overlay {
            if let shot, shot.mergeMissing, let sources = shot.mergedFrom {
                mergeAgain(sources)
            }
        }
    }

    /// Over a merged frame whose files were cleared: rebuild it only when asked.
    @ViewBuilder private func mergeAgain(_ sources: [String]) -> some View {
        if case .running = model.merging[model.mergeKey(sources)] {
            EmptyView() // progress shows at the top of the viewer
        } else {
            VStack(spacing: 10) {
                Text("This merged photo was cleared from storage.")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button {
                    model.merge(sources)
                } label: {
                    Label("Merge again", systemImage: "square.3.layers.3d")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
    }

    var body: some View {
        // The zoomable photo fills the whole pane (so zooming in uses all of it), while the
        // marks sit on the corners of where the photo is drawn at fit zoom, not at the edges
        // of the pane. The mark layer only takes touches on its controls.
        GeometryReader { geo in
            let fitted = fittedSize(in: geo.size)
            ZStack {
                photo
                Color.clear
                    .frame(width: fitted.width, height: fitted.height)
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
                            if shot?.isMerged == true {
                                Text("HDR").font(.caption2.weight(.bold)).photoCapsule()
                                    .accessibilityLabel("Merged HDR frame")
                            }
                            if let details { PhotoLabel(title: details) }
                            if loadsRAW { rawBadge }
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let swap {
                            Button(action: swap) {
                                Label("Swap", systemImage: "arrow.up.arrow.down")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(8)
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
            let fullImage = await PreviewImageLoader.shared.loadFullResolution(raw: raw, reference: shot.previewURL)
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

/// Which compare pane a filmstrip frame is in: a miniature of the stacked two-pane layout
/// with this frame's pane filled.
private struct PaneMarker: View {
    /// 0 = top pane, 1 = bottom.
    let pane: Int

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<2) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == pane ? Color.white : Color.white.opacity(0.25))
                    .frame(width: 14, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Under a frame in the filmstrip or faces panel, off the photo where it's always visible:
/// in compare which pane it's in, whether it's saving (blue) or saved (green), and a star
/// for the suggested frame. The frame on screen is shown by its outline.
private struct FrameMarker: View {
    let id: String
    let current: String
    let challenger: String?
    let suggested: String?
    let selection: SelectionCircle.Kind

    var body: some View {
        HStack(spacing: 4) {
            if challenger != nil {
                if id == current { PaneMarker(pane: 0) } else if id == challenger { PaneMarker(pane: 1) }
            }
            if selection != .unselected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, selection.color)
            }
            if id == suggested {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(.yellow)
            }
        }
        .frame(height: 16)
    }
}

/// The moment's frames in a row (the filmstrip, or the faces panel's columns): scrolls to
/// the frame on screen, outlines it (solid: shown or compare's top pane; dashed: the bottom
/// pane) and marks each frame underneath. Every other frame stays at full strength so they
/// compare fairly. Tap a frame to show it (in compare, to put it in the second pane).
private struct FrameStrip<Cell: View>: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let current: String
    let challenger: String?
    let suggested: String?
    let select: (String) -> Void
    /// Extra spoken detail for a frame (e.g. its faces).
    var detail: (String) -> [String] = { _ in [] }
    @ViewBuilder let cell: (String) -> Cell

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 2) {
                    ForEach(ids, id: \.self) { id in
                        frame(id).id(id)
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

    private func frame(_ id: String) -> some View {
        VStack(spacing: 5) {
            cell(id)
            FrameMarker(id: id, current: current, challenger: challenger, suggested: suggested,
                        selection: model.selectionState(id))
        }
        .padding(4)
        .overlay {
            if id == current {
                RoundedRectangle(cornerRadius: 9).strokeBorder(.white, lineWidth: 2.5)
            } else if id == challenger {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(id))
        .accessibilityAddTraits(.isButton)
    }

    private func label(_ id: String) -> String {
        var parts = ["Frame \((ids.firstIndex(of: id) ?? 0) + 1)"] + detail(id)
        if challenger != nil, id == current { parts.append("top pane") }
        if id == challenger { parts.append("bottom pane") }
        if challenger == nil, id == current { parts.append("shown") }
        if id == suggested { parts.append("suggested") }
        if model.shots[id]?.isMerged == true { parts.append("HDR") }
        if model.isSelected(id) { parts.append(model.isSaved(id) ? "saved" : "saving") }
        return parts.joined(separator: ", ")
    }
}

/// Every frame of the moment as a thumbnail.
private struct Filmstrip: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let current: String
    let challenger: String?
    let suggested: String?
    let select: (String) -> Void

    var body: some View {
        FrameStrip(model: model, ids: ids, current: current, challenger: challenger,
                   suggested: suggested, select: select) { id in
            PreviewImage(shot: model.shots[id])
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if model.shots[id]?.isMerged == true {
                        Text("HDR")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(3)
                    }
                }
        }
    }
}

/// Each person's face in every frame of the moment, one row per person and one column per
/// frame, so the frame where everyone looks good stands out (Faces, in place of the filmstrip).
/// Closed eyes are marked.
private struct FacesPanel: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let current: String
    let challenger: String?
    let suggested: String?
    let select: (String) -> Void

    var body: some View {
        let rows = model.faceRows(ids)
        let column = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let size: CGFloat = rows.count > 2 ? 74 : 100
        if rows.isEmpty {
            let pending = ids.filter { if case .pending = model.faceStatus($0) { true } else { false } }.count
            Text(pending > 0 ? "Finding faces… \(ids.count - pending) of \(ids.count) frames" : "No faces in this moment")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(.black)
        } else {
            FrameStrip(model: model, ids: ids, current: current, challenger: challenger,
                       suggested: suggested, select: select,
                       detail: { id in detail(rows.map { $0[column[id] ?? 0] }, id: id) }) { id in
                FacesColumn(url: model.shots[id]?.previewURL, faces: rows.map { $0[column[id] ?? 0] },
                            status: model.faceStatus(id), size: size)
            }
        }
    }

    private func detail(_ faces: [FaceBox?], id: String) -> [String] {
        switch model.faceStatus(id) {
        case .pending: return ["still finding faces"]
        case .unavailable: return ["faces not measured"]
        case .measured:
            var parts: [String] = []
            let closed = faces.compactMap { $0 }.filter { $0.eyesClosed() }.count
            let missing = faces.filter { $0 == nil }.count
            if closed > 0 { parts.append(closed == 1 ? "1 person's eyes closed" : "\(closed) people's eyes closed") }
            if missing > 0 { parts.append(missing == 1 ? "1 face not found" : "\(missing) faces not found") }
            return parts
        }
    }
}

/// One frame's close-ups, one per person, loaded together (one decode of the preview).
private struct FacesColumn: View {
    let url: URL?
    let faces: [FaceBox?]
    let status: ImportModel.FaceStatus
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: CropKey, images: [UIImage?])?

    private struct CropKey: Equatable {
        let url: URL?
        let rects: [CGRect?]
        let pixels: Int
    }

    var body: some View {
        let key = CropKey(url: url, rects: faces.map { $0?.rect },
                          pixels: PreviewImageLoader.bucket(Int(size * displayScale)))
        let images = loaded?.key == key ? loaded?.images : nil
        VStack(spacing: 4) {
            ForEach(faces.indices, id: \.self) { p in
                tile(faces[p], image: images?[p])
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: key) {
            guard let url, key.rects.contains(where: { $0 != nil }) else { return }
            let images = await PreviewImageLoader.shared.faceCrops(url: url, rects: key.rects, pixels: key.pixels)
            loaded = (key, images)
        }
    }

    /// A close-up; a spinner while the frame is measured; a question mark where the person
    /// wasn't found; plain where the frame was never measured.
    private func tile(_ face: FaceBox?, image: UIImage?) -> some View {
        ZStack {
            Color.tilePlaceholder
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if face == nil, case .pending = status {
                ProgressView().controlSize(.small).tint(.white)
            } else if face == nil, case .measured = status {
                Image(systemName: "person.fill.questionmark").foregroundStyle(.white.opacity(0.3))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if face?.eyesClosed() == true {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.orange, in: Circle())
                    .padding(3)
            }
        }
    }
}

private struct BracketRef: Identifiable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}

/// What Merge will combine, before it starts: the bracket's frames from darkest to brightest,
/// each with its exposure relative to the reference (middle) frame and its shutter speed.
private struct MergeSheet: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let merge: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let reference = model.referenceFrame(ids)
        let refExposure = reference.flatMap { model.shots[$0]?.exposure }
        let frames = ids.sorted { (model.shots[$0]?.exposure?.ev ?? 0) > (model.shots[$1]?.exposure?.ev ?? 0) }
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Merge into one HDR photo").font(.headline)
                Text("The middle exposure is the reference: it gives the midtones, the others fill shadows and highlights.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if model.fujiCamera.isHighResolution {
                    Label("\(model.fujiCamera.model) frames are large: the merge may run out of memory and close the app.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(frames, id: \.self) { id in
                    frame(id, isReference: id == reference, refExposure: refExposure)
                }
            }
            Button(action: merge) {
                Text("Merge \(ids.count) frames").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Cancel", role: .cancel) { dismiss() }
        }
        .padding(20)
    }

    private func frame(_ id: String, isReference: Bool, refExposure: Exposure?) -> some View {
        let exposure = model.shots[id]?.exposure
        return VStack(spacing: 4) {
            PreviewImage(shot: model.shots[id])
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isReference { RoundedRectangle(cornerRadius: 6).strokeBorder(.yellow, lineWidth: 2) }
                }
            Text(stops(exposure, refExposure, isReference: isReference))
                .font(.caption.weight(.semibold).monospacedDigit())
            Text(exposure.map { shutter($0.time) } ?? id)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Reference", or e.g. "+1 EV" / "−⅔ EV" relative to the reference.
    private func stops(_ e: Exposure?, _ ref: Exposure?, isReference: Bool) -> String {
        if isReference { return "Reference" }
        guard let e, let ref else { return "" }
        let s = e.stops(relativeTo: ref)
        let thirds = Int((s * 3).rounded())
        let whole = abs(thirds) / 3, rest = abs(thirds) % 3
        let fraction = rest == 0 ? "" : rest == 1 ? "⅓" : "⅔"
        let number = whole == 0 && !fraction.isEmpty ? fraction : "\(whole)\(fraction)"
        return "\(thirds < 0 ? "−" : "+")\(number) EV"
    }

    private func shutter(_ t: Double) -> String {
        t >= 1 ? String(format: "%.0f s", t) : "1/\(Int((1 / t).rounded())) s"
    }
}
