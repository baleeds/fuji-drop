import FujiDropKit
import SwiftUI
import UIKit

/// A compact bar at the bottom of every screen while picks save to Photos: progress, the
/// photo being saved, and stop. When done it offers to open Photos (and hides itself), or
/// lists failures with Retry.
struct SaveBar: View {
    @ObservedObject var saves: SaveQueue
    @ObservedObject var model: ImportModel
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
        }
    }

    private func thumbnail(_ p: SaveQueue.Progress) -> some View {
        Group {
            if let id = p.current, let image = model.shots[id]?.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: icon(p)).font(.title3).foregroundStyle(color(p))
            }
        }
        .frame(width: 40, height: 40)
        .background(Color(white: 0.5, opacity: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func title(_ p: SaveQueue.Progress) -> String {
        switch p.state {
        case .running:
            return "Saving \(min(p.done + 1, p.total)) of \(p.total)"
        case .finished where p.failures.isEmpty:
            return p.savedCount == 1 ? "Saved to Photos" : "Saved \(p.savedCount) to Photos"
        case .finished:
            return "Saved \(p.savedCount) · \(p.failures.count) failed"
        case .stopped:
            return "Stopped · saved \(p.savedCount) of \(p.total)"
        case .blocked:
            return "Allow Photos access to save"
        }
    }

    @ViewBuilder private func detail(_ p: SaveQueue.Progress) -> some View {
        switch p.state {
        case .running:
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
            if model.connection == .reconnecting {
                Text("Waiting for the camera").font(.caption).foregroundStyle(.secondary)
            }
        case .finished where !p.failures.isEmpty:
            Text(p.failures.map { "\($0.id): \($0.reason)" }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .blocked:
            Text("Fuji Drop needs permission to add photos.").font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func actions(_ p: SaveQueue.Progress) -> some View {
        switch p.state {
        case .running:
            Button("Stop", systemImage: "xmark", action: saves.cancel).labelStyle(.iconOnly)
        case .finished where p.failures.isEmpty:
            Button("Open") { openURL(URL(string: "photos-redirect://")!) }
                .buttonStyle(.bordered)
            closeButton
        case .finished:
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

    private func icon(_ p: SaveQueue.Progress) -> String {
        switch p.state {
        case .running: return "square.and.arrow.down"
        case .finished where p.failures.isEmpty: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ p: SaveQueue.Progress) -> Color {
        switch p.state {
        case .finished where p.failures.isEmpty: return .green
        case .running, .stopped: return .secondary
        default: return .orange
        }
    }
}
