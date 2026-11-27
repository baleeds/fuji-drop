import FujiDropKit
import SwiftUI

/// Live controls for the moment-grouping thresholds. Changes regroup immediately.
struct TuningView: View {
    @Binding var grouper: MomentGrouper
    let cacheUsage: PreviewCache.Usage
    let log: [CameraSession.LogLine]
    let clearCache: () -> Void
    let disconnect: () -> Void
    @AppStorage("showGroupingDetails") private var showDetails = false
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("Burst gap", value: $grouper.burstGap, range: 0.5...10, step: 0.5, format: "%.1f s")
                    row("Split above Δ", value: float($grouper.splitDistance), range: 0.1...1.5, step: 0.05, format: "%.2f")
                } header: {
                    Text("Frames close in time")
                } footer: {
                    Text("Frames within the burst gap stay together unless they look more different than the split distance.")
                }
                Section {
                    row("Join gap", value: $grouper.joinGap, range: 10...900, step: 10, format: "%.0f s")
                    row("Join below Δ", value: float($grouper.joinDistance), range: 0.05...1.0, step: 0.05, format: "%.2f")
                } header: {
                    Text("Frames further apart")
                } footer: {
                    Text("Frames up to the join gap apart rejoin a moment only if they look this similar.")
                }
                Section {
                    Toggle("Show grouping details", isOn: $showDetails)
                    Button("Reset to defaults") { grouper = MomentGrouper() }
                    LabeledContent("Current", value: summary).font(.caption.monospaced())
                } footer: {
                    Text("Details show each frame's file name, time gap and visual distance (Δ) from the previous frame.")
                }
                Section {
                    LabeledContent("Saved previews",
                                   value: "\(cacheUsage.files) · \(ByteCountFormatter.string(fromByteCount: cacheUsage.bytes, countStyle: .file))")
                    Button("Clear saved previews", role: .destructive) { confirmClear = true }
                        .disabled(cacheUsage.files == 0)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Previews are kept so reconnecting is instant. Ones unused for 30 days are removed automatically, and the total is capped at 500 MB. iOS may also clear them when storage is low.")
                }
                Section {
                    NavigationLink("Log (\(log.count))") { LogView(log: log) }
                    Button("Disconnect camera", role: .destructive, action: disconnect)
                }
            }
            .confirmationDialog("Clear saved previews?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive, action: clearCache)
            } message: {
                Text("They'll be read from the camera again next time.")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private var summary: String {
        String(format: "burst %.1fs split %.2f join %.0fs/%.2f",
               grouper.burstGap, grouper.splitDistance, grouper.joinGap, grouper.joinDistance)
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                     step: Double, format: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: format, value.wrappedValue))
            Slider(value: value, in: range, step: step)
        }
    }

    private func float(_ binding: Binding<Float>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Float($0) })
    }
}

/// The camera/import log, newest first, with a copy button for pasting into a bug report.
private struct LogView: View {
    let log: [CameraSession.LogLine]
    @State private var copied = false

    var body: some View {
        List(log.reversed()) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text(line.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Log")
        .toolbar {
            Button(copied ? "Copied" : "Copy") {
                let fmt = Date.FormatStyle().hour().minute().second()
                UIPasteboard.general.string = log
                    .map { "\($0.date.formatted(fmt))  \($0.text)" }
                    .joined(separator: "\n")
                copied = true
            }
        }
    }
}
