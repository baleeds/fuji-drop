import Combine
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
///
/// Connection lifecycle:
/// - Unplugging keeps everything (days, moments, analysis, the open screen) and shows a
///   reconnect overlay; only camera work stops.
/// - Reconnecting the same camera resumes: work for files still on the card carries over
///   (matched by `Shot.key`), files gone from the card drop out, new ones are added.
/// - A different camera starts a fresh session (views return to the day list).
/// - "Disconnect" ends the session and returns to the connect screen.
///
/// Late results are matched by `Shot.key`, so work that finishes after a reconnect or card
/// change can't land on a different file that reuses the same DSCF number.
@MainActor
final class ImportModel: ObservableObject {
    struct Shot: Identifiable {
        let id: String              // basename, e.g. DSCF3650
        let raw: ICCameraFile
        let date: Date?
        /// Camera + name + size: this exact file, across reconnects, cards and cameras.
        let key: String
        var previewURL: URL?
        var thumbnail: UIImage?
        var print: FeaturePrint?
        /// Best-shot measurements; arrive after the print.
        var score: ShotScore?
        /// Scoring failed; the shot is left out of ranking rather than holding it up.
        var scoreFailed = false
        var error: String?

        var size: Int64 { Int64(raw.fileSize) }
        var isProcessed: Bool { thumbnail != nil || error != nil }
        /// Not yet read from the camera (and not failed).
        var needsPreview: Bool { !isProcessed && previewURL == nil }
        /// Can take part in best-shot ranking (frames that failed don't block the others).
        var isRankable: Bool { error == nil && !scoreFailed }

        /// Keeps the analysis of `old`, the same file (not its errors: those retry).
        mutating func carryOver(from old: Shot) {
            previewURL = old.previewURL
            thumbnail = old.thumbnail
            print = old.print
            score = old.score
            scoreFailed = old.scoreFailed
        }
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

    enum Connection: Equatable {
        /// No session: show the connect screen.
        case none
        case connected
        /// Unplugged mid-session: keep everything and wait for the camera to come back.
        case reconnecting
    }

    /// Samples per day collage (one large, two small).
    static let samplesPerRow = 3

    let camera = CameraSession()
    private let cacheRoot = PreviewCache()
    /// The session camera's previews (its own folder under `cacheRoot`).
    private var cache: PreviewCache? { cameraID.map(cacheRoot.scoped) }
    private let rawCache = RawCache()
    /// In-flight RAF downloads by shot id, so two callers share one download. While any are
    /// running the preview queue waits: the camera answers one request at a time and a RAF
    /// someone is looking at matters more than background previews.
    private var rawDownloads: [String: Task<URL?, Never>] = [:]

    @Published private(set) var connection = Connection.none
    /// The session's camera. Kept while unplugged; changes when the session ends (nil) or a
    /// different camera replaces it, which is when views return to the root.
    @Published private(set) var cameraID: String?
    private var cameraObservation: AnyCancellable?

    @Published private(set) var days: [Day] = []
    @Published private(set) var selectedDayID: String?
    @Published private(set) var shots: [String: Shot] = [:]
    /// Shots of the selected day in time order (filename breaks ties within a second).
    @Published private(set) var order: [String] = []
    @Published private(set) var moments: [[String]] = []
    @Published private(set) var cacheUsage = PreviewCache.Usage(files: 0, bytes: 0)
    @Published private(set) var skippedNonRAW = 0
    /// Picked frames by `Shot.key`, so they survive reconnecting and never carry over to a
    /// different file (or camera) that reuses a DSCF number.
    @Published private(set) var picks: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: ImportModel.picksKey) ?? [])
    private static let picksKey = "picks.v2"
    /// Picks saved to Photos: `Shot.key` → Photos asset id. Kept so nothing saves twice.
    @Published private(set) var saved: [String: String] =
        (UserDefaults.standard.dictionary(forKey: ImportModel.savedKey) as? [String: String]) ?? [:]
    private static let savedKey = "saved.v1"
    /// Saves picks to Photos in the background (see `SaveQueue`).
    lazy var saves = SaveQueue(model: self)
    @Published var grouper = MomentGrouper() {
        didSet { if grouper != oldValue { regroup() } }
    }

    /// When preview reading for the selected day started, and how many were already done then.
    private var previewStart: (date: Date, alreadyDone: Int)?
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    /// Bumped whenever camera work stops, so a worker or read finishing late is ignored.
    private var workerGeneration = 0
    /// Feature-print distances by `Shot.key` pair, so they survive reconnecting.
    private var distanceCache: [String: Float] = [:]

    init() {
        pruneCache()
        clearRawCache() // left over from a previous session
        // The model drives its own connection state from the camera session.
        cameraObservation = camera.$catalogComplete
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main) // after the change has landed
            .sink { [weak self] complete in
                MainActor.assumeIsolated {
                    if complete { self?.catalogReady() } else { self?.cameraDisconnected() }
                }
            }
    }

    // MARK: Connection

    /// The camera's catalog is complete: start a session, or resume the current one.
    func catalogReady() {
        guard let id = camera.cameraID else { return }
        if let current = cameraID, current != id {
            camera.record("A different camera (\(id)) replaced \(current): starting over.")
            clearSession()
        }
        let resuming = cameraID == id
        cameraID = id

        let pairs = camera.shots
        let old = shots
        var fresh: [Shot] = pairs.compactMap { pair in
            pair.raw.map { file in
                Shot(id: pair.basename, raw: file, date: file.creationDate,
                     key: "\(id)/\(pair.basename)-\(file.fileSize)")
            }
        }
        var kept = 0
        for i in fresh.indices {
            if let previous = old[fresh[i].id], previous.key == fresh[i].key {
                fresh[i].carryOver(from: previous)
                kept += 1
            }
        }
        skippedNonRAW = pairs.count - fresh.count
        shots = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        days = DayGrouping.group(fresh, date: \.date).map { group in
            let sorted = group.items
                .sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
            let key = group.day.map { String(Int($0.timeIntervalSince1970)) } ?? "undated"
            return Day(id: key, date: group.day, shotIDs: sorted.map(\.id),
                       sampleIDs: TimeSampling.spread(sorted, count: Self.samplesPerRow, date: \.date).map(\.id))
        }
        let undated = fresh.filter { $0.date == nil }.count
        if resuming {
            let gone = old.values.filter { shots[$0.id]?.key != $0.key }.count
            camera.record("Reconnected: \(kept) shots resumed, \(fresh.count - kept) new, \(gone) no longer on the card.")
        } else {
            camera.record("Import: \(fresh.count) RAW shots over \(days.count) days; \(undated) undated, \(skippedNonRAW) non-RAW skipped.")
        }

        connection = .connected

        // Resume the open day (its moments, its queue), if it's still on the card.
        if let day = selectedDayID, hasDay(day) {
            select(dayID: day)
        } else {
            selectedDayID = nil
            order = []
            moments = []
        }
        // Day collage samples, newest day first.
        loadDaySamples()
    }

    /// The camera went away (unplugged, turned off). Keep the session; stop camera work.
    func cameraDisconnected() {
        guard connection == .connected else { return }
        connection = .reconnecting
        stopCameraWork()
        camera.record("Camera disconnected: keeping your place until it's back.")
    }

    /// Ends the session on purpose: back to the connect screen.
    func endSession() {
        clearSession()
        camera.stop()
    }

    private func clearSession() {
        saves.reset()
        stopCameraWork()
        clearRawCache()
        cameraID = nil
        connection = .none
        days = []; selectedDayID = nil; shots = [:]; order = []; moments = []
        previewStart = nil; distanceCache = [:]
    }

    /// Stops everything that talks to the camera. Analysis of previews already on disk
    /// carries on: it doesn't need the camera.
    private func stopCameraWork() {
        worker?.cancel()
        worker = nil
        workerGeneration += 1
        queue = []
        rawDownloads.values.forEach { $0.cancel() }
        rawDownloads = [:]
    }

    /// Whether camera work started at `generation` still belongs to the live connection.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == workerGeneration && connection == .connected
    }

    /// The ids still on the card (after reconnecting with a changed card, some may be gone).
    func onCard(_ ids: [String]) -> [String] {
        ids.filter { shots[$0] != nil }
    }

    func hasDay(_ id: String) -> Bool {
        days.contains { $0.id == id }
    }

    /// Applies a change to a shot only if it's still the same file.
    @discardableResult
    private func update(_ id: String, key: String, _ change: (inout Shot) -> Void) -> Bool {
        guard var shot = shots[id], shot.key == key else { return false }
        change(&shot)
        shots[id] = shot
        return true
    }

    // MARK: Day → previews

    func select(dayID: String) {
        guard let day = days.first(where: { $0.id == dayID }) else { return }
        selectedDayID = dayID
        order = day.shotIDs
        previewStart = (Date(), dayProcessed)
        regroup()
        enqueue(order, atFront: true)
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


    // MARK: Preview queue

    /// Re-queues the day collage samples (clearing earlier failures so they retry).
    func loadDaySamples() {
        enqueue(days.flatMap(\.sampleIDs), atFront: false)
    }

    /// Queues shots that need a preview. Earlier failures are cleared so they retry.
    private func enqueue(_ ids: [String], atFront: Bool) {
        for id in ids where shots[id]?.error != nil {
            shots[id]?.error = nil
            shots[id]?.previewURL = nil
        }
        let wanted = ids.filter { shots[$0]?.needsPreview == true }
        let set = Set(wanted)
        queue.removeAll { set.contains($0) }
        queue = atFront ? wanted + queue : queue + wanted
        guard connection == .connected, !queue.isEmpty, worker == nil else { return }
        camera.record("Preview queue: starting with \(queue.count) shots.")
        let generation = workerGeneration
        worker = Task { [weak self] in
            var loaded = 0
            while let self, !Task.isCancelled, let id = self.nextQueued() {
                while !self.rawDownloads.isEmpty, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
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
            self.pruneCache()
        }
    }

    private func nextQueued() -> String? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    private func loadPreview(_ id: String) async {
        guard let shot = shots[id], shot.needsPreview, let cache else { return }
        let key = shot.key, size = shot.size
        let generation = workerGeneration
        do {
            // Cache file I/O off the main actor.
            let url: URL
            if let cached = await Task.detached(priority: .userInitiated, operation: {
                cache.cachedURL(name: id, size: size)
            }).value {
                url = cached
            } else {
                let preview = try await camera.embeddedPreview(of: shot.raw)
                // Disconnected or reset while reading: drop it (the shot is queued again on resume).
                guard isCurrent(generation) else { return }
                url = try await Task.detached(priority: .userInitiated) {
                    try cache.store(preview.jpeg, name: id, size: size)
                }.value
            }
            guard update(id, key: key, { $0.previewURL = url }) else { return }
            analyse(id, key: key, url: url)
        } catch {
            // A read cut short by unplugging isn't a problem with the file.
            guard isCurrent(generation) else { return }
            update(id, key: key) { $0.error = error.localizedDescription }
            camera.record("Preview \(id) failed: \(error.localizedDescription)")
        }
    }

    private var decodeLogCount = 0

    /// Thumbnail first so photos appear quickly, then the Vision print (serial, slower), then
    /// best-shot scoring. Works from the cached file, so it carries on while unplugged; it
    /// never blocks reading the next preview.
    private func analyse(_ id: String, key: String, url: URL) {
        let logDetail = decodeLogCount < 3
        decodeLogCount += 1
        Task { [weak self] in
            let t0 = Date()
            let thumb = await Background.decode { ImageLoading.thumbnail(at: url, maxPixelSize: 360) }
            if logDetail {
                self?.camera.record(String(format: "Decode %@: %@ in %.2f s", id, thumb == nil ? "failed" : "ok", Date().timeIntervalSince(t0)))
            }
            guard let self, self.finishThumbnail(id, key: key, thumb) else { return }
            let t1 = Date()
            let print = await Background.vision { () -> FeaturePrint? in
                guard let small = ImageLoading.thumbnail(at: url, maxPixelSize: 512) else { return nil }
                return try? FeaturePrinter.featurePrint(of: small)
            }
            if logDetail {
                self.camera.record(String(format: "Vision %@: %@ in %.2f s", id, print == nil ? "failed" : "ok", Date().timeIntervalSince(t1)))
            }
            guard self.update(id, key: key, { $0.print = print }) else { return }
            if self.order.contains(id) { self.regroup() }
            await self.scoreShot(id, key: key, url: url, log: logDetail)
        }
    }

    /// Measures focus, faces and aesthetics on the full 1920 px preview.
    private func scoreShot(_ id: String, key: String, url: URL, log: Bool) async {
        let t0 = Date()
        let measured = await Background.score { () -> (CGImage, ShotScore)? in
            guard let image = ImageLoading.thumbnail(at: url, maxPixelSize: 1920),
                  let score = try? ShotScorer.measure(image) else { return nil }
            return (image, score)
        }
        guard let measured else {
            update(id, key: key) { $0.scoreFailed = true }
            camera.record("Score \(id): failed")
            return
        }
        let image = measured.0
        var score = measured.1
        score.aesthetics = await ShotScorer.aesthetics(of: image)
        if log {
            camera.record(String(format: "Score %@ in %.2f s: sharp %.0f, face %@, aesthetics %@",
                                 id, Date().timeIntervalSince(t0), score.sharpness,
                                 score.faceQuality.map { String(format: "%.2f", $0) } ?? "none",
                                 score.aesthetics.map { String(format: "%.2f", $0) } ?? "none"))
        }
        update(id, key: key) { $0.score = score }
    }

    /// Returns whether analysis should continue.
    private func finishThumbnail(_ id: String, key: String, _ thumbnail: CGImage?) -> Bool {
        let applied: Bool
        if let thumbnail {
            applied = update(id, key: key) { $0.thumbnail = UIImage(cgImage: thumbnail) }
        } else {
            // A cached file that doesn't decode would fail forever: drop it so a retry reads
            // the preview from the camera again.
            let cache = self.cache
            applied = update(id, key: key) {
                cache?.remove(name: $0.id, size: $0.size)
                $0.error = "Could not decode preview"
                $0.previewURL = nil
            }
            camera.record("Preview \(id): could not decode; removed from the cache so it's read again.")
        }
        // No regroup: grouping uses dates and prints, which a thumbnail doesn't change.
        return applied && thumbnail != nil
    }

    // MARK: Full RAF

    /// The shot's RAF if it's already downloaded.
    func cachedRawURL(_ id: String) -> URL? {
        guard let shot = shots[id] else { return nil }
        return rawCache.cachedURL(name: id, size: shot.size)
    }

    /// A shot's RAF: the cached copy, or a download (about 1.4 s for 33 MB). While the camera
    /// is unplugged this waits for it to come back (a download cut off by unplugging is
    /// retried), so callers never need to check the connection. Nil only if the download
    /// fails, the file is no longer on the card, the session ends, or the caller is cancelled.
    func rawURL(_ id: String) async -> URL? {
        guard let key = shots[id]?.key else { return nil }
        while !Task.isCancelled {
            guard shots[id]?.key == key else { return nil }
            if let cached = cachedRawURL(id) { return cached }
            switch connection {
            case .none:
                return nil
            case .reconnecting:
                for await state in $connection.values where state != .reconnecting { break }
            case .connected:
                if let url = await download(id) { return url }
                // Failed while still connected: a real failure. Otherwise unplugged; loop.
                if connection == .connected { return nil }
            }
        }
        return nil
    }

    /// One RAF download, shared by concurrent callers.
    private func download(_ id: String) async -> URL? {
        guard let shot = shots[id] else { return nil }
        if let running = rawDownloads[id] { return await running.value }
        let cache = rawCache
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            let started = Date()
            do {
                let downloaded = try await self.camera.download(shot.raw, to: cache.incoming)
                try Task.checkCancellation()
                let url = try await Task.detached(priority: .userInitiated) {
                    let url = try cache.adopt(downloaded, name: shot.id, size: shot.size)
                    cache.prune()
                    return url
                }.value
                self.camera.record(String(format: "RAF %@: %.1f MB in %.2f s", shot.id,
                                          Double(shot.size) / 1_000_000, Date().timeIntervalSince(started)))
                return url
            } catch {
                if !Task.isCancelled {
                    self.camera.record("RAF \(shot.id) failed: \(error.localizedDescription)")
                }
                return nil
            }
        }
        rawDownloads[id] = task
        let url = await task.value
        // Only clear our own entry: a reset may have replaced it with a newer download.
        if rawDownloads[id] == task { rawDownloads[id] = nil }
        return url
    }

    private func clearRawCache() {
        let cache = rawCache
        Task.detached(priority: .utility) { cache.clear() }
    }

    // MARK: Preview cache

    /// Trims the cache (30 days unused, 500 MB cap, all cameras) off the main actor, then
    /// refreshes usage. Runs at launch and whenever the preview queue goes idle.
    func pruneCache() {
        let cache = cacheRoot
        Task {
            let result = await Task.detached(priority: .utility) { cache.prune() }.value
            if result.removed.files > 0 {
                camera.record("Preview cache: removed \(result.removed.files) old previews (\(result.removed.bytes / 1_000_000) MB).")
            }
            cacheUsage = result.remaining
        }
    }

    func clearCache() {
        let cache = cacheRoot
        Task {
            _ = await Task.detached(priority: .utility) { cache.clear() }.value
            cacheUsage = await Task.detached { cache.usage() }.value
        }
    }

    // MARK: Moments

    private func regroup() {
        // Undated shots (camera clock never set) have no time to group by: keep each one on
        // its own, spaced far apart, instead of collapsing them all into one moment.
        let items = order.enumerated().compactMap { index, id in
            shots[id].map { ($0, $0.date ?? Date(timeIntervalSinceReferenceDate: -1e9 + Double(index) * 86400)) }
        }
        moments = grouper
            .group(items, date: { $0.1 }, distance: { [self] a, b in distance(a.0, b.0) })
            .map { $0.map { $0.0.id } }
    }

    private func distance(_ a: Shot, _ b: Shot) -> Float? {
        let key = "\(a.key)|\(b.key)"
        if let cached = distanceCache[key] { return cached }
        guard let pa = a.print, let pb = b.print, let d = pa.distance(to: pb) else { return nil }
        distanceCache[key] = d
        return d
    }

    /// A moment's label: its time, or the first file name for undated shots.
    func timeLabel(of ids: [String]) -> String {
        guard let first = ids.first else { return "" }
        return shots[first]?.date?.formatted(date: .omitted, time: .shortened) ?? first
    }

    /// A moment's best-shot ranking: each frame's breakdown (score parts and flaws such as
    /// "Soft focus") and the suggested frame (nil for single frames).
    struct Ranking {
        let breakdowns: [String: BestShot.Breakdown]
        let suggested: String?
    }

    /// Ranks a moment once every frame that can be scored is scored. Frames that failed
    /// (unreadable preview, scoring error) are left out rather than holding up the rest.
    /// Compute it once per render and read everything from it.
    func ranking(of ids: [String]) -> Ranking? {
        let candidates = ids.filter { shots[$0]?.isRankable == true }
        let scores = candidates.compactMap { shots[$0]?.score }
        guard !candidates.isEmpty, scores.count == candidates.count else { return nil }
        let ranked = BestShot.rank(scores)
        let best = ids.count > 1 ? BestShot.bestIndex(ranked).map { candidates[$0] } : nil
        return Ranking(breakdowns: Dictionary(uniqueKeysWithValues: zip(candidates, ranked)), suggested: best)
    }

    /// The frame that stands for a moment: the owner's pick, else the suggestion, else the
    /// middle frame that loaded (so the feed doesn't flicker or lead with a failed frame).
    func hero(of ids: [String], ranking: Ranking? = nil) -> String {
        if let pick = picked(in: ids) ?? (ranking ?? self.ranking(of: ids))?.suggested { return pick }
        let usable = ids.filter { shots[$0]?.error == nil }
        let pool = usable.isEmpty ? ids : usable
        return pool[pool.count / 2]
    }

    // MARK: Picks

    func isPicked(_ id: String) -> Bool {
        shots[id].map { picks.contains($0.key) } ?? false
    }

    /// The moment's picked frame, if the owner chose one.
    func picked(in ids: [String]) -> String? {
        ids.first(where: isPicked)
    }

    /// Makes `id` the moment's one pick (nil clears it).
    func setPick(_ id: String?, in ids: [String]) {
        for other in ids { if let key = shots[other]?.key { picks.remove(key) } }
        if let id, let key = shots[id]?.key { picks.insert(key) }
        UserDefaults.standard.set(Array(picks), forKey: Self.picksKey)
    }

    func isSaved(_ id: String) -> Bool {
        shots[id].map { saved[$0.key] != nil } ?? false
    }

    func markSaved(key: String, assetID: String) {
        saved[key] = assetID
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
    }

    /// Picked frames among `ids` not yet in Photos, in time order.
    func unsavedPicks(in ids: [String]) -> [String] {
        ids.filter { isPicked($0) && !isSaved($0) }
    }

    /// The two frames compare opens with: the current favourite on top (pick, else suggestion,
    /// else middle) and the best-ranked other frame (else the next frame in time) below.
    func compareStart(in ids: [String]) -> (top: String, bottom: String) {
        let ranking = ranking(of: ids)
        let top = hero(of: ids, ranking: ranking)
        let others = ids.filter { $0 != top }
        guard !others.isEmpty else { return (top, top) }
        if let totals = ranking?.breakdowns.mapValues(\.total),
           let best = others.max(by: { (totals[$0] ?? -1) < (totals[$1] ?? -1) }) {
            return (top, best)
        }
        let i = ids.firstIndex(of: top) ?? 0
        return (top, i + 1 < ids.count ? ids[i + 1] : ids[i - 1])
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
