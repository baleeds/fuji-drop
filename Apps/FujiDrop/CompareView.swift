import FujiDropKit
import SwiftUI
import UIKit

/// Two frames of a moment at once, zoom and pan locked together. Landscape frames stack top
/// and bottom; portrait frames sit side by side.
///
/// Winner stays: the first pane is the current favourite, the second is the challenger.
/// Tap a frame in the filmstrip to challenge with it; "Pick this" on the challenger swaps it
/// in as the favourite. "Pick" saves the favourite as the moment's pick.
/// The pair compare opens with, chosen once by `ImportModel.compareStart`.
struct CompareStart: Identifiable {
    let favourite: String
    let challenger: String
    var id: String { favourite + "|" + challenger }
}

struct CompareView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var favourite: String
    @State private var challenger: String
    @State private var group = ZoomGroup()

    init(model: ImportModel, ids: [String], start: CompareStart) {
        self.model = model
        self.ids = ids
        _favourite = State(initialValue: start.favourite)
        _challenger = State(initialValue: start.challenger)
    }

    var body: some View {
        let sideBySide = model.aspect(favourite, clamped: false) < 1
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        let breakdowns = model.ranking(of: ids)?.breakdowns
        NavigationStack {
            VStack(spacing: 0) {
                layout {
                    ComparePane(model: model, shot: model.shots[favourite],
                                flaws: breakdowns?[favourite]?.flaws ?? [], group: group,
                                connection: model.connection, promote: nil)
                    ComparePane(model: model, shot: model.shots[challenger],
                                flaws: breakdowns?[challenger]?.flaws ?? [], group: group,
                                connection: model.connection) {
                        let previous = favourite
                        favourite = challenger
                        challenger = previous
                    }
                }
                Filmstrip(model: model, ids: model.onCard(ids), favourite: favourite, challenger: challenger) { id in
                    if id != favourite { challenger = id }
                }
            }
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // After a reconnect the card may have changed; a new session means another camera.
            .onChange(of: model.connection) {
                if model.shots[favourite] == nil || model.shots[challenger] == nil { dismiss() }
            }
            .onChange(of: model.cameraID) { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pick") {
                        model.setPick(favourite, in: ids)
                        dismiss()
                    }
                }
            }
        }
    }

    private var title: String {
        let position = { (id: String) in (ids.firstIndex(of: id) ?? 0) + 1 }
        return "\(position(favourite)) vs \(position(challenger)) of \(ids.count)"
    }
}

/// One side of the comparison, zoomable with the other side: the 1920 px preview at once,
/// then the full-resolution RAF once it has downloaded and decoded (a few seconds).
private struct ComparePane: View {
    let model: ImportModel
    let shot: ImportModel.Shot?
    let flaws: [BestShot.Flaw]
    let group: ZoomGroup
    /// A change (reconnecting) re-runs loading, so a RAW download cut off by unplugging is
    /// retried.
    let connection: ImportModel.Connection
    /// Swaps this pane in as the favourite; nil for the favourite itself.
    let promote: (() -> Void)?
    @State private var image: UIImage?
    @State private var full: FullState = .loading

    private enum FullState { case loading, ready, failed }

    /// Up to 8× in compare: enough for 100 % of a 4896 px RAF in a half-width pane.
    private static let maxZoom: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, group: group, maxZoom: Self.maxZoom)
            } else if let thumbnail = shot?.thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if promote == nil { SuggestedBadge(label: "Favourite") }
        }
        .overlay(alignment: promote == nil ? .topTrailing : .topLeading) {
            FlawTip(flaws: flaws)
        }
        .overlay(alignment: .bottomTrailing) {
            if let promote {
                Button(action: promote) {
                    Label("Pick this", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) { rawBadge }
        .task(id: TaskKey(id: shot?.id, preview: shot?.previewURL, connection: connection)) {
            // Keep showing the previous frame until the new one decodes (usually from the
            // in-memory cache), so the zoomable view and its viewport carry over.
            guard let shot else { image = nil; return }
            // Already decoded (e.g. after swapping panes): show it straight away.
            if let raw = model.cachedRawURL(shot.id), let decoded = PreviewImageLoader.shared.cachedFullResolution(raw: raw) {
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
            // Then the real pixels. The download continues if this pane moves on to another
            // frame, so switching back is instant.
            guard let raw = await model.rawURL(shot.id), !Task.isCancelled else {
                // While unplugged this stays "loading": the reconnect re-runs this task.
                if !Task.isCancelled, model.connection == .connected { full = .failed }
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
        let connection: ImportModel.Connection
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

/// Every frame of the moment; tap one to compare it against the favourite.
private struct Filmstrip: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    let favourite: String
    let challenger: String
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
            .onAppear { proxy.scrollTo(challenger, anchor: .center) }
        }
        .background(.black)
    }

    private func thumbnail(_ id: String) -> some View {
        let border: Color = id == favourite ? .yellow : id == challenger ? .white : .clear
        return PreviewImage(shot: model.shots[id])
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 2.5))
            .overlay(alignment: .topTrailing) {
                if id == favourite {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                        .padding(4)
                } else if model.isPicked(id) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.blue)
                        .padding(3)
                }
            }
            .opacity(id == favourite || id == challenger ? 1 : 0.6)
            .accessibilityLabel("Frame \((ids.firstIndex(of: id) ?? 0) + 1)")
            .accessibilityAddTraits(.isButton)
    }
}
