import FujiDropKit
import ImageCaptureCore
import SwiftUI
import UIKit

/// Import pipeline for the main app: camera catalog → shooting days → embedded RAF previews
/// (cached on disk) → thumbnails + Vision feature prints → moments.
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
    }

    struct Day: Identifiable, Hashable {
        let id: String
        let date: Date?
        let shotIDs: [String]

        var title: String {
            let when = date.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "Undated"
            return "\(when) · \(shotIDs.count) shots"
        }
    }

    let camera = CameraSession()
    private let cache = PreviewCache()

    @Published private(set) var days: [Day] = []
    @Published private(set) var selectedDayID: String?
    @Published private(set) var shots: [String: Shot] = [:]
    /// Shots of the selected day in time order (filename breaks ties within a second).
    @Published private(set) var order: [String] = []
    @Published private(set) var moments: [[String]] = []
    @Published private(set) var previewsLoaded = 0
    /// When preview reading for the selected day started, and how many were already done then.
    private var previewStart: (date: Date, alreadyLoaded: Int)?
    @Published private(set) var cacheUsage = PreviewCache.Usage(files: 0, bytes: 0)
    @Published private(set) var skippedNonRAW = 0
    @Published var grouper = MomentGrouper() {
        didSet { if grouper != oldValue { regroup() } }
    }

    private var loadTask: Task<Void, Never>?
    private var distanceCache: [String: Float] = [:]

    // MARK: Catalog → days

    init() {
        pruneCache()
    }

    func catalogReady() {
        let pairs = camera.shots
        let rawShots = pairs.compactMap { pair in
            pair.raw.map { Shot(id: pair.basename, raw: $0, date: $0.creationDate) }
        }
        skippedNonRAW = pairs.count - rawShots.count
        shots = Dictionary(uniqueKeysWithValues: rawShots.map { ($0.id, $0) })

        days = DayGrouping.group(rawShots, date: \.date).map { group in
            let ids = group.items
                .sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
                .map(\.id)
            let key = group.day.map { String(Int($0.timeIntervalSince1970)) } ?? "undated"
            return Day(id: key, date: group.day, shotIDs: ids)
        }
        let undated = rawShots.filter { $0.date == nil }.count
        camera.record("Import: \(rawShots.count) RAW shots over \(days.count) days; \(undated) undated, \(skippedNonRAW) non-RAW skipped.")
        if let newest = days.first { select(dayID: newest.id) }
    }

    func reset() {
        loadTask?.cancel()
        days = []; selectedDayID = nil; shots = [:]; order = []; moments = []
        previewsLoaded = 0; distanceCache = [:]
    }

    // MARK: Day → previews

    func select(dayID: String) {
        guard let day = days.first(where: { $0.id == dayID }) else { return }
        loadTask?.cancel()
        selectedDayID = dayID
        order = day.shotIDs
        previewsLoaded = order.filter { shots[$0]?.thumbnail != nil || shots[$0]?.error != nil }.count
        previewStart = (Date(), previewsLoaded)
        regroup()
        let ids = order
        loadTask = Task { [weak self] in
            for id in ids {
                if Task.isCancelled { return }
                await self?.loadPreview(id)
            }
        }
    }

    private func loadPreview(_ id: String) async {
        guard let shot = shots[id], shot.thumbnail == nil, shot.error == nil else { return }
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
            // Decode + Vision off the main actor; don't wait for it before reading the next preview.
            Task { [weak self] in
                let (thumb, print) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, FeaturePrint?) in
                    let thumb = ImageLoading.thumbnail(at: url, maxPixelSize: 360)
                    let small = ImageLoading.thumbnail(at: url, maxPixelSize: 512)
                    let print = small.flatMap { try? FeaturePrinter.featurePrint(of: $0) }
                    return (thumb, print)
                }.value
                self?.finish(id, thumbnail: thumb, print: print)
            }
        } catch {
            shots[id]?.error = error.localizedDescription
            camera.record("Preview \(id) failed: \(error.localizedDescription)")
            previewsLoaded += 1
        }
    }

    private func finish(_ id: String, thumbnail: CGImage?, print: FeaturePrint?) {
        shots[id]?.thumbnail = thumbnail.map { UIImage(cgImage: $0) }
        shots[id]?.print = print
        if thumbnail == nil { shots[id]?.error = "Could not decode preview" }
        previewsLoaded += 1
        if previewsLoaded == order.count { refreshCacheUsage() }
        regroup()
    }

    /// Rough time left for the selected day's previews, once there's enough to estimate from.
    var previewTimeRemaining: TimeInterval? {
        guard let start = previewStart else { return nil }
        let done = previewsLoaded - start.alreadyLoaded
        let left = order.count - previewsLoaded
        guard done >= 5, left > 0 else { return nil }
        return Date().timeIntervalSince(start.date) / Double(done) * Double(left)
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
