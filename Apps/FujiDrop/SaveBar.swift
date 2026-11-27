import FujiDropKit
import SwiftUI
import UIKit

/// A compact bar at the bottom of every screen while picks save to Photos: progress, the
/// photo being saved, and stop. When done it offers to open Photos (and hides itself after
/// a few seconds), or lists failures with Retry. Drawn above the reconnect overlay, so it
/// says when saving is waiting for the camera.
struct SaveBar: View {
    @ObservedObject var saves: SaveQueue
    let waitingForCamera: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let p = saves.progress {
            HStack(spacing: 12) {
                thumbnail(p)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(p)).font(.subheadline.weight(.semibold))
                    detail(p)
                }
                Spacer(minLength: 0)
                actions(p)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.default, value: p)
            // A clean run hides itself; failures stay until dismissed or retried.
            .task(id: p.phase) {
                guard p.phase == .done else { return }
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { saves.dismiss() }
            }
        }
    }

    private func thumbnail(_ p: SaveQueue.Progress) -> some View {
        let (symbol, color) = icon(p.phase)
        return Group {
            if let image = p.current {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
            }
        }
        .frame(width: 40, height: 40)
        .background(Color(white: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func title(_ p: SaveQueue.Progress) -> String {
        switch p.phase {
        case .saving: return "Saving \(p.position) of \(p.total)"
        case .done: return p.savedCount == 1 ? "Saved to Photos" : "Saved \(p.savedCount) to Photos"
        case .partial: return "Saved \(p.savedCount) · \(p.failures.count) failed"
        case .stopped: return "Stopped · saved \(p.savedCount) of \(p.total)"
        case .blocked: return "Allow Photos access to save"
        }
    }

    @ViewBuilder private func detail(_ p: SaveQueue.Progress) -> some View {
        switch p.phase {
        case .saving:
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
            if waitingForCamera {
                Text("Paused until the camera is back").font(.caption).foregroundStyle(.secondary)
            }
        case .partial:
            Text(p.failures.map { "\($0.id): \($0.reason)" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .blocked:
            Text("Fuji Drop needs permission to add photos.").font(.caption).foregroundStyle(.secondary)
        case .done, .stopped:
            EmptyView()
        }
    }

    @ViewBuilder private func actions(_ p: SaveQueue.Progress) -> some View {
        switch p.phase {
        case .saving:
            Button("Stop", systemImage: "xmark", action: saves.cancel).labelStyle(.iconOnly)
        case .done:
            Button("Open") { openURL(URL(string: "photos-redirect://")!) }.buttonStyle(.bordered)
            closeButton
        case .partial:
            Button("Retry", action: saves.retryFailed).buttonStyle(.bordered)
            closeButton
        case .stopped:
            closeButton
        case .blocked:
            Button("Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                .buttonStyle(.bordered)
            Button("Try Again", action: saves.resume).buttonStyle(.bordered)
        }
    }

    private var closeButton: some View {
        Button("Close", systemImage: "xmark", action: saves.dismiss).labelStyle(.iconOnly)
    }

    private func icon(_ phase: SaveQueue.Progress.Phase) -> (String, Color) {
        switch phase {
        case .saving: return ("square.and.arrow.down", .secondary)
        case .done: return ("checkmark.circle.fill", .green)
        case .partial, .blocked: return ("exclamationmark.triangle.fill", .orange)
        case .stopped: return ("stop.circle", .secondary)
        }
    }
}
