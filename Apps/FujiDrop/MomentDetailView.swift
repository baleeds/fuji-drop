import FujiDropKit
import SwiftUI

/// All frames of one moment, full width, top to bottom. Tap a frame to zoom.
struct MomentDetailView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @AppStorage("showGroupingDetails") private var showDetails = false
    @State private var viewing: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(ids, id: \.self) { id in
                    PreviewImage(shot: model.shots[id])
                        .aspectRatio(model.aspect(id, clamped: false), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .bottomLeading) {
                            if showDetails { PhotoLabel(title: details(id)) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { viewing = id }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { viewing.map { Viewing(id: $0) } }, set: { viewing = $0?.id })) { v in
            PreviewSheet(shot: model.shots[v.id])
        }
    }

    private var title: String {
        let time = ids.first.flatMap { model.shots[$0]?.date }?.formatted(date: .omitted, time: .shortened) ?? ""
        return ids.count == 1 ? time : "\(time) · \(ids.count) frames"
    }

    /// Calibration info: file name, time gap and visual distance from the previous frame.
    private func details(_ id: String) -> String {
        let step = model.stepFromPrevious(id)
        var parts = [id]
        if let gap = step.gap { parts.append(String(format: "+%.0f s", gap)) }
        if let d = step.distance { parts.append(String(format: "Δ %.2f", d)) }
        return parts.joined(separator: " · ")
    }

    private struct Viewing: Identifiable { let id: String }
}

/// The full 1920×1280 preview, zoomable.
private struct PreviewSheet: View {
    let shot: ImportModel.Shot?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    if let url = shot?.previewURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                            .gesture(MagnifyGesture().onChanged { scale = max(1, min(4, $0.magnification)) })
                            .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2.5 }
                    } else {
                        Text("Preview not loaded yet").foregroundStyle(.secondary)
                    }
                }
            }
            .background(.black)
            .navigationTitle(shot?.id ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
