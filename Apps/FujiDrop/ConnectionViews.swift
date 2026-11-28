import FujiDropKit
import SwiftUI

/// Covers the screen while the camera is unplugged mid-session. The screen underneath stays
/// as it was; reconnecting the same camera removes the overlay and resumes.
struct ReconnectOverlay: View {
    @ObservedObject var camera: CameraSession
    let startOver: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Camera disconnected").font(.title3.weight(.semibold))
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if case .failed = camera.phase {
                    Button("Try again") {
                        Task {
                            camera.stop()
                            await camera.start()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView().padding(.top, 4)
                }
                Button("Disconnect", role: .destructive, action: startOver)
                    .padding(.top, 12)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        switch camera.phase {
        case .opening(let name): return "Reconnecting to \(name)…"
        case .loadingCatalog, .failed: return camera.phase.statusText
        default:
            return "Plug the camera back in and turn it on to carry on where you left off. Photos still waiting to save will finish then."
        }
    }
}

extension CameraSession.Phase {
    /// What the connect screen says for each phase; the reconnect overlay reuses some.
    var statusText: String {
        switch self {
        case .idle: return "Connect your camera"
        case .waitingForAuthorization: return "Waiting for permission…"
        case .searching: return "Looking for the camera…"
        case .opening(let n): return "Opening \(n)…"
        case .loadingCatalog(let n): return "Reading \(n)'s card…"
        case .ready(let n): return "\(n) ready"
        case .failed(let reason): return reason
        }
    }
}

/// Shown when the open day or moment isn't on the card after reconnecting.
struct NotOnCardView: View {
    var body: some View {
        ContentUnavailableView("Not on this card", systemImage: "sdcard",
                               description: Text("These photos are no longer on the camera's card."))
    }
}

extension View {
    /// Shows `ReconnectOverlay` while `model` is waiting for its camera to come back.
    /// Apply on every full-screen presentation, since a cover hides the root's overlay.
    func reconnectOverlay(_ model: ImportModel) -> some View {
        modifier(ReconnectOverlayModifier(model: model))
    }
}

private struct ReconnectOverlayModifier: ViewModifier {
    @ObservedObject var model: ImportModel

    func body(content: Content) -> some View {
        content.overlay {
            if model.connection == .reconnecting {
                ReconnectOverlay(camera: model.camera, startOver: model.endSession)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: model.connection)
    }
}
