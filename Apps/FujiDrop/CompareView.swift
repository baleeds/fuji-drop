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
                    ComparePane(shot: model.shots[favourite], flaws: flaws[favourite] ?? [], group: group,
                                isFavourite: true, promote: {})
                    ComparePane(shot: model.shots[challenger], flaws: flaws[challenger] ?? [], group: group,
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

/// One side of the comparison: the frame's 1920 px preview, zoomable with the other side.
private struct ComparePane: View {
    let shot: ImportModel.Shot?
    let flaws: [BestShot.Flaw]
    let group: ZoomGroup
    let isFavourite: Bool
    let promote: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                ZoomableImage(image: image, group: group)
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
        .task(id: shot?.previewURL) {
            // Keep showing the previous frame until the new one decodes (usually from the
            // in-memory cache), so the zoomable view and its viewport carry over.
            guard let url = shot?.previewURL else { image = nil; return }
            image = await PreviewImageLoader.shared.load(url: url, maxPixelSize: 1920)
        }
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
