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
        case .loadingCatalog(let name): return "Reading \(name)'s card…"
        case .failed(let reason): return reason
        default:
            return "Plug the camera back in and turn it on to carry on where you left off. Your picks are kept."
        }
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
