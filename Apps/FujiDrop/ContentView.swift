import FujiDropKit
import SwiftUI

/// App shell. The real flow is: Import → Moments → Compare & pick → Save → Share.
/// Each screen is a placeholder until the spike confirms the transfer path.
struct ContentView: View {
    enum Stage: String, CaseIterable, Identifiable {
        case importShots = "Import"
        case moments = "Moments"
        case compare = "Compare"
        case save = "Save to Photos"
        case share = "Share"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .importShots: return "cable.connector"
            case .moments: return "square.stack.3d.up"
            case .compare: return "rectangle.split.2x1"
            case .save: return "photo.on.rectangle"
            case .share: return "square.and.arrow.up"
            }
        }

        var summary: String {
            switch self {
            case .importShots: return "Pull previews from the X-T1 over USB-C (ImageCaptureCore)."
            case .moments: return "Group by capture time, then split/merge with Vision feature prints."
            case .compare: return "Synced loupe, focus overlay, suggested pick per moment."
            case .save: return "Fetch the picked RAFs and save RAW+JPEG to Photos."
            case .share: return "Hand off to Instagram via the share sheet."
            }
        }
    }

    var body: some View {
        NavigationStack {
            List(Stage.allCases) { stage in
                NavigationLink(value: stage) {
                    Label {
                        VStack(alignment: .leading) {
                            Text(stage.rawValue)
                            Text(stage.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: stage.systemImage)
                    }
                }
            }
            .navigationTitle("Fuji Drop")
            .navigationDestination(for: Stage.self) { stage in
                ContentUnavailableView(stage.rawValue, systemImage: stage.systemImage,
                                       description: Text("Not built yet. \(stage.summary)"))
            }
        }
    }
}

#Preview {
    ContentView()
}
