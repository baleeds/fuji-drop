import FujiDropKit
import ImageCaptureCore
import SwiftUI
import UIKit

/// Import pipeline for the main app: camera catalog → shooting days → embedded RAF previews
/// (cached on disk) → thumbnails + Vision feature prints → moments.
///
/// Previews load through one serial queue (the camera answers one read at a time). On connect
/// it loads a few spread-out samples per day for the days list; opening a day moves that day's
/// shots to the front.
@MainActor
final class ImportModel: ObservableObject {
    struct Shot: Identifiable {
        let id: String              // basename, e.g. DSCF3650
        let raw: ICCameraFile
        let date: Date?
        var previewURL: URL?
        var thumbnail: UIImage?
        var print: FeaturePrint?
        var error: String?

        var isProcessed: Bool { thumbnail != nil || error != nil }
    }

    struct Day: Identifiable, Hashable {
        let id: String
        let date: Date?
        let shotIDs: [String]       // time order
        let sampleIDs: [String]     // spread across the day

        var title: String {
            date.map { $0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) } ?? "Undated"
        }
    }

    /// Samples per day collage (one large, two small).
    static let samplesPerRow = 3

    let camera = CameraSession()
    private let cache = PreviewCache()

    @Published private(set) var days: [Day] = []
    @Published private(set) var selectedDayID: String?
    @Published private(set) var shots: [String: Shot] = [:]
    /// Shots of the selected day in time order (filename breaks ties within a second).
    @Published private(set) var order: [String] = []
    @Published private(set) var moments: [[String]] = []
    @Published private(set) var cacheUsage = PreviewCache.Usage(files: 0, bytes: 0)
    @Published private(set) var skippedNonRAW = 0
    @Published var grouper = MomentGrouper() {
        didSet { if grouper != oldValue { regroup() } }
    }

    /// When preview reading for the selected day started, and how many were already done then.
    private var previewStart: (date: Date, alreadyDone: Int)?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    /// Bumped on reset so a cancelled worker finishing late can't clear its successor.
    private var workerGeneration = 0
    private var distanceCache: [String: Float] = [:]

    init() {
        pruneCache()
    }

    // MARK: Catalog → days

    func catalogReady() {
        let pairs = camera.shots
        let rawShots = pairs.compactMap { pair in
            pair.raw.map { Shot(id: pair.basename, raw: $0, date: $0.creationDate) }
        }
        skippedNonRAW = pairs.count - rawShots.count
        shots = Dictionary(uniqueKeysWithValues: rawShots.map { ($0.id, $0) })

        days = DayGrouping.group(rawShots, date: \.date).map { group in
            let sorted = group.items
                .sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
            let key = group.day.map { String(Int($0.timeIntervalSince1970)) } ?? "undated"
            return Day(id: key, date: group.day, shotIDs: sorted.map(\.id),
                       sampleIDs: TimeSampling.spread(sorted, count: Self.samplesPerRow, date: \.date).map(\.id))
        }
        let undated = rawShots.filter { $0.date == nil }.count
        camera.record("Import: \(rawShots.count) RAW shots over \(days.count) days; \(undated) undated, \(skippedNonRAW) non-RAW skipped.")

        // Day collage samples first, newest day first.
        loadDaySamples()
    }

    func reset() {
        worker?.cancel()
        worker = nil
        workerGeneration += 1
        queue = []
        days = []; selectedDayID = nil; shots = [:]; order = []; moments = []
        previewStart = nil; distanceCache = [:]
    }

    // MARK: Day → previews

    func select(dayID: String) {
        guard let day = days.first(where: { $0.id == dayID }) else { return }
        selectedDayID = dayID
        order = day.shotIDs
        previewStart = (Date(), dayProcessed)
        regroup()
        enqueue(order, atFront: true, retryFailed: true)
    }

    /// Selected day's shots that have a thumbnail (or failed).
    var dayProcessed: Int { order.filter { shots[$0]?.isProcessed == true }.count }

    /// Rough time left for the selected day's previews, once there's enough to estimate from.
    var previewTimeRemaining: TimeInterval? {
        guard let start = previewStart else { return nil }
        let done = dayProcessed - start.alreadyDone
        let left = order.count - dayProcessed
        guard done >= 5, left > 0 else { return nil }
        return Date().timeIntervalSince(start.date) / Double(done) * Double(left)
    }

    func dayTimeSpan(_ day: Day) -> String? {
        guard let first = day.shotIDs.first.flatMap({ shots[$0]?.date }),
              let last = day.shotIDs.last.flatMap({ shots[$0]?.date }) else { return nil }
        let a = first.formatted(date: .omitted, time: .shortened)
        let b = last.formatted(date: .omitted, time: .shortened)
        return a == b ? a : "\(a) – \(b)"
    }

    /// Display aspect ratio (width / height) of a shot. Clamped by default so portrait frames
    /// crop to 4:5 in feeds; pass `clamped: false` to show the whole frame.
    func aspect(_ id: String, clamped: Bool = true) -> CGFloat {
        guard let size = shots[id]?.thumbnail?.size, size.height > 0 else { return 1.5 }
        let ratio = size.width / size.height
        return clamped ? min(max(ratio, 0.8), 1.6) : ratio
    }

    /// Up to `count` ids spread across the given shots' time span.
    func samples(of ids: [String], count: Int = ImportModel.samplesPerRow) -> [String] {
        TimeSampling.spread(ids, count: count, date: { self.shots[$0]?.date })
    }

    // MARK: Preview queue

    /// Re-queues the day collage samples (clearing earlier failures so they retry).
    func loadDaySamples() {
        enqueue(days.flatMap(\.sampleIDs), atFront: false, retryFailed: true)
    }

    private func enqueue(_ ids: [String], atFront: Bool, retryFailed: Bool = false) {
        if retryFailed {
            for id in ids where shots[id]?.error != nil {
                shots[id]?.error = nil
                shots[id]?.previewURL = nil
            }
        }
        let wanted = ids.filter { shots[$0]?.isProcessed == false }
        let set = Set(wanted)
        queue.removeAll { set.contains($0) }
        queue = atFront ? wanted + queue : queue + wanted
        guard !queue.isEmpty, worker == nil else { return }
        camera.record("Preview queue: starting with \(queue.count) shots.")
        let generation = workerGeneration
        worker = Task { [weak self] in
            var loaded = 0
            while let self, !Task.isCancelled, let id = self.nextQueued() {
                let started = Date()
                await self.loadPreview(id)
                loaded += 1
                if loaded <= 3 || loaded % 25 == 0 {
                    self.camera.record(String(format: "Preview queue: %@ done in %.2f s (%d so far, %d queued)",
                                              id, Date().timeIntervalSince(started), loaded, self.queue.count))
                }
            }
            guard let self, self.workerGeneration == generation else { return }
            self.camera.record("Preview queue: idle after \(loaded) shots.")
            self.worker = nil
            self.refreshCacheUsage()
        }
    }

    private func nextQueued() -> String? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func loadPreview(_ id: String) async {
        guard let shot = shots[id], !shot.isProcessed, shot.previewURL == nil else { return }
        let size = Int64(shot.raw.fileSize)
        do {
            let url: URL
            if let cached = cache.cachedURL(name: id, size: size) {
                url = cached
            } else {
                let preview = try await camera.embeddedPreview(of: shot.raw)
                url = try cache.store(preview.jpeg, name: id, size: size)
            }
            shots[id]?.previewURL = url
            // Thumbnail first so photos appear quickly, then the Vision print (serial, slower).
            // Neither blocks reading the next preview.
            let logDetail = decodeLogCount < 3
            decodeLogCount += 1
            Task { [weak self] in
                let t0 = Date()
                let thumb = await Background.decode { ImageLoading.thumbnail(at: url, maxPixelSize: 360) }
                if logDetail {
                    self?.camera.record(String(format: "Decode %@: %@ in %.2f s", id, thumb == nil ? "failed" : "ok", Date().timeIntervalSince(t0)))
                }
                self?.finishThumbnail(id, thumb)
                guard thumb != nil else { return }
                let t1 = Date()
                let print = await Background.vision { () -> FeaturePrint? in
                    guard let small = ImageLoading.thumbnail(at: url, maxPixelSize: 512) else { return nil }
                    return try? FeaturePrinter.featurePrint(of: small)
                }
                if logDetail {
                    self?.camera.record(String(format: "Vision %@: %@ in %.2f s", id, print == nil ? "failed" : "ok", Date().timeIntervalSince(t1)))
                }
                self?.finishPrint(id, print)
            }
        } catch {
            shots[id]?.error = error.localizedDescription
            camera.record("Preview \(id) failed: \(error.localizedDescription)")
        }
    }

    private var decodeLogCount = 0

    private func finishThumbnail(_ id: String, _ thumbnail: CGImage?) {
        if let thumbnail {
            shots[id]?.thumbnail = UIImage(cgImage: thumbnail)
        } else {
            shots[id]?.error = "Could not decode preview"
            camera.record("Preview \(id): could not decode \(shots[id]?.previewURL?.lastPathComponent ?? "?")")
        }
        if order.contains(id) { regroup() }
    }

    private func finishPrint(_ id: String, _ print: FeaturePrint?) {
        shots[id]?.print = print
        if order.contains(id) { regroup() }
    }

    // MARK: Preview cache

    /// Trims the cache (30 days unused, 500 MB cap) off the main actor, then refreshes usage.
    func pruneCache() {
        let cache = self.cache
        Task {
            let result = await Task.detached(priority: .utility) { cache.prune() }.value
            if result.removed.files > 0 {
                camera.record("Preview cache: removed \(result.removed.files) old previews (\(result.removed.bytes / 1_000_000) MB).")
            }
            cacheUsage = result.remaining
        }
    }

    func clearCache() {
        let cache = self.cache
        Task {
            _ = await Task.detached(priority: .utility) { cache.clear() }.value
            cacheUsage = await Task.detached { cache.usage() }.value
        }
    }

    private func refreshCacheUsage() {
        let cache = self.cache
        Task { cacheUsage = await Task.detached(priority: .utility) { cache.usage() }.value }
    }

    // MARK: Moments

    private func regroup() {
        let items = order.compactMap { shots[$0] }
        moments = grouper
            .group(items, date: { $0.date ?? .distantPast }, distance: { [self] a, b in distance(a, b) })
            .map { $0.map(\.id) }
    }

    private func distance(_ a: Shot, _ b: Shot) -> Float? {
        let key = "\(a.id)|\(b.id)"
        if let cached = distanceCache[key] { return cached }
        guard let pa = a.print, let pb = b.print, let d = pa.distance(to: pb) else { return nil }
        distanceCache[key] = d
        return d
    }

    /// Time gap and visual distance from the previous frame in time order, for calibration.
    func stepFromPrevious(_ id: String) -> (gap: TimeInterval?, distance: Float?) {
        guard let i = order.firstIndex(of: id), i > 0,
              let current = shots[id], let previous = shots[order[i - 1]] else { return (nil, nil) }
        var gap: TimeInterval?
        if let c = current.date, let p = previous.date { gap = c.timeIntervalSince(p) }
        return (gap, distance(previous, current))
    }
}
