import FujiDropKit
import SwiftUI

/// All frames of one moment, with each frame's step from the previous frame
/// (time gap and Vision distance) shown for calibrating the grouping thresholds.
struct MomentDetailView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @State private var viewing: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 12) {
                ForEach(ids, id: \.self) { id in
                    Button { viewing = id } label: { cell(id) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
            Text("Δ is the visual distance to the previous frame (smaller = more similar). Use these numbers with the grouping settings to tune splits.")
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
        }
        .navigationTitle(ids.count == 1 ? "1 shot" : "\(ids.count) shots")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { viewing.map { Viewing(id: $0) } }, set: { viewing = $0?.id })) { v in
            PreviewSheet(shot: model.shots[v.id])
        }
    }

    private func cell(_ id: String) -> some View {
        let step = model.stepFromPrevious(id)
        return VStack(alignment: .leading, spacing: 2) {
            ShotThumbnail(shot: model.shots[id], height: 110)
                .frame(maxWidth: .infinity)
            Text(id).font(.caption.monospaced())
            Text(stepText(step)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func stepText(_ step: (gap: TimeInterval?, distance: Float?)) -> String {
        var parts: [String] = []
        if let gap = step.gap { parts.append(String(format: "+%.0f s", gap)) }
        if let d = step.distance { parts.append(String(format: "Δ %.2f", d)) }
        return parts.isEmpty ? "first" : parts.joined(separator: " · ")
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
            .navigationTitle(shot?.id ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
