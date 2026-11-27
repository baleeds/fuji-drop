import FujiDropKit
import SwiftUI
import UIKit

/// Two frames of a moment at once, zoom and pan locked together. Landscape frames stack top
/// and bottom; portrait frames sit side by side.
///
/// Winner stays: the first pane is the current favourite, the second is the challenger.
/// Tap a frame in the filmstrip to challenge with it; "Pick this" on the challenger swaps it
/// in as the favourite. "Pick" saves the favourite as the moment's pick.
struct CompareView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var favourite: String
    @State private var challenger: String
    @State private var group = ZoomGroup()

    init(model: ImportModel, ids: [String]) {
        self.model = model
        self.ids = ids
        let start = model.compareStart(in: ids)
        _favourite = State(initialValue: start.top)
        _challenger = State(initialValue: start.bottom)
    }

    var body: some View {
        let sideBySide = model.aspect(favourite, clamped: false) < 1
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        let flaws = model.flaws(in: ids)
        NavigationStack {
            VStack(spacing: 0) {
                layout {
                    ComparePane(model: model, shot: model.shots[favourite], flaws: flaws[favourite] ?? [], group: group,
                                isFavourite: true, promote: {})
                    ComparePane(model: model, shot: model.shots[challenger], flaws: flaws[challenger] ?? [], group: group,
                                isFavourite: false) {
                        let previous = favourite
                        favourite = challenger
                        challenger = previous
                    }
                }
                Filmstrip(model: model, ids: ids, favourite: favourite, challenger: challenger) { id in
                    if id != favourite { challenger = id }
                }
            }
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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

/// Full-resolution decodes of downloaded RAFs. Only a couple are kept: each is ~64 MB.
@MainActor
final class FullResolutionLoader {
    static let shared = FullResolutionLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var running: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 200_000_000
    }

    /// An already decoded image, without waiting.
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url.lastPathComponent as NSString)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let task = running[url] { return await task.value }
        let task = Task { () -> UIImage? in
            await Background.raw {
                (try? RAWRenderer.renderImage(from: url)).map { UIImage(cgImage: $0) }
            }
        }
        running[url] = task
        let image = await task.value
        running[url] = nil
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

/// One side of the comparison, zoomable with the other side: the 1920 px preview at once,
/// then the full-resolution RAF once it has downloaded and decoded (a few seconds).
private struct ComparePane: View {
    let model: ImportModel
    let shot: ImportModel.Shot?
    let flaws: [BestShot.Flaw]
    let group: ZoomGroup
    let isFavourite: Bool
    let promote: () -> Void
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
            if isFavourite {
                Label("Favourite", systemImage: "star.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .padding(7)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(10)
            }
        }
        .overlay(alignment: isFavourite ? .topTrailing : .topLeading) {
            FlawTip(flaws: flaws)
        }
        .overlay(alignment: .bottomTrailing) {
            if !isFavourite {
                Button(action: promote) {
                    Label("Pick this", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) { rawBadge }
        .task(id: TaskKey(id: shot?.id, preview: shot?.previewURL)) {
            // Keep showing the previous frame until the new one decodes (usually from the
            // in-memory cache), so the zoomable view and its viewport carry over.
            guard let shot else { image = nil; return }
            // Already decoded (e.g. after swapping panes): show it straight away.
            if let raw = model.cachedRawURL(shot.id), let decoded = FullResolutionLoader.shared.cached(raw) {
                image = decoded
                full = .ready
                return
            }
            full = .loading
            if let url = shot.previewURL {
                let preview = await PreviewImageLoader.shared.load(url: url, maxPixelSize: 1920)
                guard !Task.isCancelled else { return }
                image = preview
            }
            // Then the real pixels. The download continues if this pane moves on to another
            // frame, so switching back is instant.
            guard let raw = await model.rawURL(shot.id), !Task.isCancelled else {
                if !Task.isCancelled { full = .failed }
                return
            }
            let fullImage = await FullResolutionLoader.shared.image(for: raw)
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
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(10)
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
