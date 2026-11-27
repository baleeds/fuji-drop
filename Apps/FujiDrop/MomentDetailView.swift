import FujiDropKit
import SwiftUI
import UIKit

/// All frames of one moment, full width, top to bottom, with the pick (or suggestion) marked.
/// Tap a frame to zoom, long-press to pick it, or compare two frames side by side.
struct MomentDetailView: View {
    @ObservedObject var model: ImportModel
    let ids: [String]
    @AppStorage("showGroupingDetails") private var showDetails = false
    @State private var viewing: String?
    @State private var comparing = false

    var body: some View {
        let picked = model.picked(in: ids)
        let suggested = picked == nil ? model.suggested(in: ids) : nil
        let ranking = showDetails ? model.ranking(of: ids) : nil
        let flaws = model.flaws(in: ids)
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(ids, id: \.self) { id in
                    PreviewImage(shot: model.shots[id])
                        .aspectRatio(model.aspect(id, clamped: false), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topLeading) {
                            FlawTip(flaws: flaws[id] ?? [])
                        }
                        .overlay(alignment: .topTrailing) {
                            if id == picked { PickedBadge() } else if id == suggested { SuggestedBadge() }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if showDetails {
                                VStack(alignment: .leading, spacing: -14) {
                                    if let r = ranking?[id] { PhotoLabel(title: scoreDetails(r)) }
                                    PhotoLabel(title: details(id))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { viewing = id }
                        .contextMenu {
                            if id == picked {
                                Button("Remove Pick", systemImage: "xmark") { model.setPick(nil, in: ids) }
                            } else {
                                Button("Pick", systemImage: "checkmark") { model.setPick(id, in: ids) }
                            }
                            if ids.count > 1 {
                                Button("Compare", systemImage: "square.split.1x2") { comparing = true }
                            }
                        }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if ids.count > 1 {
                Button("Compare", systemImage: "square.split.1x2") { comparing = true }
            }
        }
        .fullScreenCover(isPresented: $comparing) {
            CompareView(model: model, ids: ids)
        }
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

    /// Calibration info: each part of the best-shot score (0–100) and the total.
    private func scoreDetails(_ r: BestShot.Breakdown) -> String {
        func pct(_ v: Float) -> String { String(Int((v * 100).rounded())) }
        var parts = ["focus \(pct(r.sharpness))"]
        if let face = r.face { parts.append("face \(pct(face))") }
        if let aesthetics = r.aesthetics { parts.append("look \(pct(aesthetics))") }
        if let eyes = r.eyeOpenness { parts.append("eyes \(pct(eyes))") }
        parts.append("= \(pct(r.total))")
        return parts.joined(separator: " · ")
    }

    private struct Viewing: Identifiable { let id: String }
}

/// The full 1920×1280 preview, zoomable.
private struct PreviewSheet: View {
    let shot: ImportModel.Shot?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImage(image: image)
                } else {
                    Text("Preview not loaded yet").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(.black)
            .navigationTitle(shot?.id ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .task(id: shot?.previewURL) {
            image = shot?.previewURL.flatMap { UIImage(contentsOfFile: $0.path) }
        }
    }
}
