import UIKit
import FujiDropKit
import ImageCaptureCore
import ImageIO
import SwiftUI

/// Drives the four "risks to test first" from the research doc and collects a
/// pasteable report.
@MainActor
final class SpikeModel: ObservableObject {
    enum Status: String {
        case pending = "○", running = "…", pass = "✅", fail = "❌", info = "ℹ️"
    }

    struct Check: Identifiable {
        let id: Int
        let title: String
        var status: Status = .pending
        var detail = ""
    }

    struct Thumb: Identifiable {
        var id: String { basename }
        let basename: String
        let source: String
        let image: UIImage?
        let pixelSize: CGSize
        let bytes: Int
        let millis: Int
        let error: String?

        var sizeText: String { error == nil ? "\(Int(pixelSize.width))×\(Int(pixelSize.height))" : "error" }
    }

    let camera = CameraSession()

    @Published var checks: [Check] = [
        Check(id: 1, title: "ImageCaptureCore sees the X-T1 and lists its files"),
        Check(id: 2, title: "Thumbnails over PTP are big enough to judge sharpness"),
        Check(id: 3, title: "RAF + JPEG save to Photos as one paired asset"),
        Check(id: 4, title: "Camera clock over PTP: read/set works or fails not-authorized"),
    ]
    @Published var thumbs: [Thumb] = []
    @Published var selected: String?
    @Published var downloadedJPEG: Thumb?
    @Published var busy = false

    private var workDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spike", isDirectory: true)
    }

    // MARK: 1. Connect

    func connect() async {
        set(1, .running, "Requesting access and browsing…")
        await camera.start()
        if case .failed(let reason) = camera.phase { set(1, .fail, reason) }
    }

    /// Called whenever the camera's state changes, so check 1 tracks reality.
    func refreshConnectionCheck() {
        switch camera.phase {
        case .ready(let name):
            let shots = camera.shots
            let pairs = shots.filter(\.isComplete).count
            if camera.files.isEmpty {
                set(1, .fail, "\(name): catalog complete but 0 files.")
            } else {
                set(1, .pass, "\(name): \(camera.files.count) files, \(shots.count) shots, \(pairs) RAF+JPEG pairs. Contents auth \(camera.contentsAuthorization), control auth \(camera.controlAuthorization).")
            }
        case .failed(let reason):
            set(1, .fail, reason)
        case .searching:
            set(1, .running, "Searching… is the camera on and in MTP(PTP) USB mode?")
        case .opening(let name), .loadingCatalog(let name):
            set(1, .running, "\(name): opening session / loading catalog…")
        case .idle, .waitingForAuthorization:
            break
        }
    }

    // MARK: 2. Thumbnails

    func testThumbnails(count: Int = 12) async {
        let shots = Array(camera.shots.suffix(count))
        guard !shots.isEmpty else { return set(2, .fail, "No shots on the camera.") }
        busy = true; defer { busy = false }
        set(2, .running, "Fetching \(shots.count) thumbnails…")
        thumbs = []
        for shot in shots {
            guard let file = shot.jpeg ?? shot.raw else { continue }
            thumbs.append(await fetchThumb(shot.basename, file))
        }
        // One RAF thumbnail on its own, since Fuji RAW thumbs behave differently over the cable.
        var rafNote = "no RAF on card"
        if let shot = shots.last(where: { $0.raw != nil }), let raf = shot.raw {
            let t = await fetchThumb(shot.basename, raf)
            rafNote = t.error.map { "RAF thumb error: \($0)" } ?? "RAF thumb \(t.sizeText), \(t.bytes / 1024) KB"
        }
        if selected == nil { selected = thumbs.last?.basename }

        let ok = thumbs.filter { $0.error == nil }
        guard let largest = ok.map({ max($0.pixelSize.width, $0.pixelSize.height) }).max() else {
            return set(2, .fail, "No thumbnails decoded. \(thumbs.first?.error ?? "") \(rafNote)")
        }
        let sizes = Set(ok.map(\.sizeText)).sorted().joined(separator: ", ")
        let avgMs = ok.map(\.millis).reduce(0, +) / max(ok.count, 1)
        let verdict = largest >= 1024
            ? "Long edge ≥ 1024 px: probably usable for scoring."
            : "Long edge < 1024 px: too small to judge focus; plan to score the in-camera JPEG."
        set(2, largest >= 1024 ? .pass : .info,
            "\(ok.count)/\(thumbs.count) decoded. Sizes: \(sizes). Avg \(avgMs) ms each. \(rafNote). \(verdict) Open one at 100% to judge by eye.")
    }

    private func fetchThumb(_ basename: String, _ file: ICCameraFile) async -> Thumb {
        let start = Date()
        do {
            let data = try await camera.thumbnailData(for: file)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let (image, size) = Self.decode(data)
            return Thumb(basename: basename, source: file.name ?? "?", image: image,
                         pixelSize: size, bytes: data.count, millis: ms, error: nil)
        } catch {
            return Thumb(basename: basename, source: file.name ?? "?", image: nil,
                         pixelSize: .zero, bytes: 0, millis: 0, error: error.localizedDescription)
        }
    }

    /// Downloads the selected shot's in-camera JPEG: the fallback scoring source.
    func downloadSelectedJPEG() async {
        guard let shot = selectedShot, let jpeg = shot.jpeg else { return }
        busy = true; defer { busy = false }
        let start = Date()
        do {
            let url = try await camera.download(jpeg, to: workDir.appendingPathComponent(shot.basename))
            let secs = Date().timeIntervalSince(start)
            let data = try Data(contentsOf: url)
            let (image, size) = Self.decode(data)
            downloadedJPEG = Thumb(basename: shot.basename, source: url.lastPathComponent, image: image,
                                   pixelSize: size, bytes: data.count, millis: Int(secs * 1000), error: nil)
            camera.record(String(format: "Downloaded %@: %.1f MB in %.2f s (%.1f MB/s)",
                                 url.lastPathComponent, Double(data.count) / 1e6, secs, Double(data.count) / 1e6 / secs))
        } catch {
            camera.record("JPEG download failed: \(error.localizedDescription)")
        }
    }

    // MARK: 3. Save pair to Photos

    var selectedShot: ShotPair<ICCameraFile>? {
        camera.shots.first { $0.basename == selected }
    }

    func testSavePair() async {
        guard let shot = selectedShot ?? camera.shots.last(where: \.isComplete) else {
            return set(3, .fail, "No shot selected.")
        }
        guard let jpegFile = shot.jpeg, let rawFile = shot.raw else {
            return set(3, .fail, "\(shot.basename) is not a RAF+JPEG pair. Shoot one in FINE+RAW and select it.")
        }
        busy = true; defer { busy = false }
        set(3, .running, "Downloading \(shot.basename) JPG + RAF…")
        do {
            let dir = workDir.appendingPathComponent(shot.basename)
            let t0 = Date()
            let jpeg = try await camera.download(jpegFile, to: dir)
            let t1 = Date()
            let raw = try await camera.download(rawFile, to: dir)
            let t2 = Date()
            let rawMB = Double((try? raw.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1e6
            let timing = String(format: "JPG %.2f s, RAF %.1f MB in %.2f s (%.1f MB/s)",
                                t1.timeIntervalSince(t0), rawMB, t2.timeIntervalSince(t1),
                                rawMB / max(t2.timeIntervalSince(t1), 0.001))
            camera.record("Downloaded pair: \(timing)")

            set(3, .running, "Saving to Photos…")
            let id = try await PhotoSaver.savePair(jpeg: jpeg, raw: raw)
            let resources = PhotoSaver.resources(forAssetID: id)
            let listing = resources.map(\.description).joined(separator: "; ")
            let paired = resources.contains { $0.type == .photo } && resources.contains { $0.type == .alternatePhoto }
            set(3, paired ? .pass : .fail,
                "\(timing). Asset resources: \(listing.isEmpty ? "none found" : listing). Check Photos shows a single item labelled RAW+JPEG.")
        } catch {
            set(3, .fail, "Failed: \(error.localizedDescription)")
        }
    }

    // MARK: 4. Clock over PTP

    @Published var cameraClock: String?

    func testReadClock() async {
        busy = true; defer { busy = false }
        set(4, .running, "Sending GetDeviceInfo…")
        let info = await camera.sendPTP(PTP.Operation.getDeviceInfo.rawValue)
        logPTP("GetDeviceInfo", info)
        if let error = info.errorDescription {
            return set(4, isNotAuthorized(error) ? .info : .fail,
                       "PTP pass-through blocked: \(error). Clock sync is not possible from iOS; drop it from day 1.")
        }

        set(4, .running, "Reading DateTime (0x5011)…")
        let read = await camera.sendPTP(PTP.Operation.getDevicePropValue.rawValue,
                                        params: [UInt32(PTP.Property.dateTime.rawValue)])
        logPTP("GetDevicePropValue(DateTime)", read)
        if let error = read.errorDescription {
            return set(4, .fail, "GetDeviceInfo worked but DateTime read failed: \(error)")
        }
        guard read.response?.isOK == true else {
            return set(4, .fail, "DateTime read returned \(read.response?.name ?? "no response").")
        }
        guard let decoded = PTP.decodeString(read.payload) else {
            return set(4, .fail, "DateTime payload not a PTP string: \(PTP.hex(read.payload))")
        }
        let text = decoded.0
        cameraClock = text
        let driftText: String
        if let date = PTP.parseDateTime(text) {
            driftText = String(format: "camera is %+.0f s vs phone", date.timeIntervalSinceNow)
        } else {
            driftText = "could not parse"
        }
        set(4, .pass, "Read works. Camera clock \(text) (\(driftText)). Try Set to test writing.")
    }

    func testSetClock() async {
        busy = true; defer { busy = false }
        let now = PTP.formatDateTime(Date())
        let result = await camera.sendPTP(PTP.Operation.setDevicePropValue.rawValue,
                                          params: [UInt32(PTP.Property.dateTime.rawValue)],
                                          outData: PTP.encodeString(now))
        logPTP("SetDevicePropValue(DateTime=\(now))", result)
        if let error = result.errorDescription {
            return set(4, .info, "Read status kept; write failed: \(error)")
        }
        if result.response?.isOK == true {
            set(4, .pass, "Read and write both work. Set camera clock to \(now). Read again to confirm.")
        } else {
            set(4, .info, "Write returned \(result.response?.name ?? "no response"). Reading may still work.")
        }
    }

    private func isNotAuthorized(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("not authorized") || t.contains("notauthorized") || t.contains("not permitted")
    }

    private func logPTP(_ label: String, _ r: CameraSession.PTPResult) {
        camera.record("""
        PTP \(label): cmd [\(PTP.hex(r.command))] → \
        response \(r.response.map { "\($0.name) params \($0.params)" } ?? "unparsed [\(PTP.hex(r.responseData))]"), \
        data \(r.dataIn.count) B [\(PTP.hex(r.dataIn, limit: 32))]\
        \(r.errorDescription.map { ", error \($0)" } ?? "")
        """)
    }

    // MARK: Report

    var report: String {
        var lines = ["# Fuji Drop spike report", "Generated \(Date().formatted())", ""]
        lines.append("Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        if let cam = camera.camera {
            lines.append("Camera: \(cam.name ?? "?"), transport \(cam.transportType ?? "?"), capabilities \(cam.capabilities)")
        }
        lines.append("")
        for c in checks { lines.append("\(c.status.rawValue) \(c.id). \(c.title)\n   \(c.detail)") }
        if let j = downloadedJPEG {
            lines.append("\nIn-camera JPEG: \(j.sizeText), \(j.bytes / 1024) KB, \(j.millis) ms")
        }
        lines.append("\n## Log")
        let fmt = Date.FormatStyle().hour().minute().second()
        lines += camera.log.map { "\($0.date.formatted(fmt))  \($0.text)" }
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    private func set(_ id: Int, _ status: Status, _ detail: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].status = status
        checks[i].detail = detail
    }

    static func decode(_ data: Data) -> (UIImage?, CGSize) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return (nil, .zero) }
        return (UIImage(cgImage: cg), CGSize(width: cg.width, height: cg.height))
    }
}
