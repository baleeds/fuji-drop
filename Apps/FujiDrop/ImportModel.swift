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
        /// Exposure settings from the preview's EXIF, for finding brackets.
        var exposure: Exposure?
        /// A merged HDR frame: the bracket's frame ids, in time order. Nil for camera frames.
        /// Its `raw` is the first frame's file (only for its size); it's never read from the
        /// camera, and its "RAW" is the merged DNG (`rawURL`).
        var mergedFrom: [String]?

        var isMerged: Bool { mergedFrom != nil }

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
            exposure = old.exposure
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
    /// Selected frames by `Shot.key` (any number per moment), so they survive reconnecting
    /// and never carry over to a different file (or camera) that reuses a DSCF number.
    @Published private(set) var picks: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: ImportModel.picksKey) ?? [])
    private static let picksKey = "picks.v2"
    /// Selections saved to Photos: `Shot.key` → Photos asset id. Kept so nothing saves twice,
    /// and so deselecting can delete the asset.
    @Published private(set) var saved: [String: String] =
        (UserDefaults.standard.dictionary(forKey: ImportModel.savedKey) as? [String: String]) ?? [:]
    private static let savedKey = "saved.v1"
    /// The format each save used (`SaveFormat`), by `Shot.key`, so changing the setting later
    /// neither re-saves anything nor leaves it unclear what's in Photos. Absent = RAF (saves
    /// from before the setting existed).
    private(set) var savedFormats: [String: String] =
        (UserDefaults.standard.dictionary(forKey: ImportModel.savedFormatsKey) as? [String: String]) ?? [:]
    private static let savedFormatsKey = "savedFormats.v1"
    /// Saves selections to Photos in the background (see `SaveQueue`).
    lazy var saves = SaveQueue(model: self)
    @Published var grouper = MomentGrouper() {
        didSet { if grouper != oldValue { regroup() } }
    }
    /// Exposure brackets of the selected day (frame ids in time order), and each frame's.
    @Published private(set) var brackets: [[String]] = []
    private var bracketOf: [String: Int] = [:]
    let bracketFinder = BracketFinder()
    /// HDR merges running or failed, by merge key (see `mergeKey`).
    @Published private(set) var merging: [String: MergeState] = [:]
    private var mergeTasks: [String: Task<MergeCache.Entry?, Never>] = [:]
    private let mergeCache = MergeCache()
    /// Finished merges on disk, by merge key, so `regroup` and the viewer never touch the file
    /// system on the main actor. Filled when a merge finishes and by one background lookup per
    /// bracket (`mergeLookups`); cleared after pruning so the lookups run again.
    private var mergeEntries: [String: MergeCache.Entry] = [:]
    private var mergeLookups: Set<String> = []
    /// Brackets merged at some point, by merge key, so their HDR frame shows (and is rebuilt
    /// if the cache was pruned) whenever the day is open.
    private var knownMerges = Set(UserDefaults.standard.stringArray(forKey: ImportModel.mergesKey) ?? [])
    private static let mergesKey = "merges.v1"

    enum MergeState: Equatable {
        case running(String)
        case failed(String)
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
        // Selections whose save was cut off (unplugged, app closed) carry on.
        saves.save(unsavedSelections())
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
        brackets = []; bracketOf = [:]
        mergeTasks.values.forEach { $0.cancel() }
        mergeTasks = [:]; merging = [:]
        mergeEntries = [:]; mergeLookups = []
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
            let (thumb, exposure) = await Background.decode {
                (ImageLoading.thumbnail(at: url, maxPixelSize: 360), Exposure(contentsOf: url))
            }
            if logDetail {
                self?.camera.record(String(format: "Decode %@: %@ in %.2f s", id, thumb == nil ? "failed" : "ok", Date().timeIntervalSince(t0)))
            }
            guard let self, self.finishThumbnail(id, key: key, thumb) else { return }
            self.update(id, key: key) { $0.exposure = exposure }
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
        if let sources = shot.mergedFrom { return mergeEntries[mergeKey(sources)]?.dng }
        return rawCache.cachedURL(name: id, size: shot.size)
    }

    /// A shot's RAF: the cached copy, or a download (about 1.4 s for 33 MB). While the camera
    /// is unplugged this waits for it to come back (a download cut off by unplugging is
    /// retried), so callers never need to check the connection. Nil only if the download
    /// fails, the file is no longer on the card, the session ends, or the caller is cancelled.
    func rawURL(_ id: String) async -> URL? {
        guard let key = shots[id]?.key else { return nil }
        // A merged frame's RAW is its DNG, merged again if the cache lost it.
        if let sources = shots[id]?.mergedFrom { return await mergedEntry(sources)?.dng }
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
                // A read can fail a moment before the unplug is reported: let it settle, then
                // a failure while still connected is real. Otherwise loop and wait.
                try? await Task.sleep(for: .seconds(1))
                if connection == .connected, camera.catalogComplete { return nil }
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
        var grouped = grouper
            .group(items, date: { $0.1 }, distance: { [self] a, b in distance(a.0, b.0) })
            .map { $0.map { $0.0.id } }

        // Brackets, kept within one moment, each followed by its HDR frame once merged.
        let ranges = bracketFinder.find(items, date: { $0.0.date }, exposure: { $0.0.exposure },
                                        distance: { [self] a, b in distance(a.0, b.0) })
        let found = ranges.map { r in items[r].map { $0.0.id } }
        if found != brackets { brackets = found }
        bracketOf = [:]
        for (i, ids) in found.enumerated() { for id in ids { bracketOf[id] = i } }
        grouped = BracketFinder.keepTogether(grouped, brackets: found)
        for ids in found where knownMerges.contains(mergeKey(ids)) {
            let merged = addMergedShot(ids)
            if let m = grouped.firstIndex(where: { $0.contains(ids.last!) }),
               let i = grouped[m].firstIndex(of: ids.last!) {
                grouped[m].insert(merged, at: i + 1)
            }
        }
        moments = grouped
    }

    // MARK: Brackets and HDR merges

    /// The bracket a frame belongs to (frame ids in time order), if any.
    func bracket(of id: String) -> [String]? {
        if let sources = shots[id]?.mergedFrom { return sources }
        return bracketOf[id].map { brackets[$0] }
    }

    /// Stable key of a bracket's merge: its frames' exact files.
    func mergeKey(_ ids: [String]) -> String {
        MergeCache.key(for: ids.map { shots[$0]?.key ?? $0 })
    }

    /// The merged frame's id for a bracket, e.g. `DSCF2729-HDR`.
    func mergedID(_ ids: [String]) -> String { "\(ids.first ?? "")-HDR" }

    func isMerged(_ ids: [String]) -> Bool { knownMerges.contains(mergeKey(ids)) }

    /// The reference (middle exposure) frame of a bracket.
    func referenceFrame(_ ids: [String]) -> String? {
        let exposures = ids.compactMap { shots[$0]?.exposure }
        guard exposures.count == ids.count, !ids.isEmpty else { return ids.first }
        return ids[BracketFinder.referenceIndex(exposures)]
    }

    /// Adds (or refreshes) the synthetic HDR frame for a merged bracket and returns its id.
    @discardableResult
    private func addMergedShot(_ ids: [String]) -> String {
        let id = mergedID(ids)
        let key = "\(cameraID ?? "")/merge-\(mergeKey(ids))"
        guard let first = ids.first.flatMap({ shots[$0] }) else { return id }
        let entry = mergeEntries[mergeKey(ids)]
        if entry == nil { lookUpMerge(ids) }
        if var existing = shots[id], existing.key == key {
            if existing.previewURL != entry?.jpeg {
                existing.previewURL = entry?.jpeg
                shots[id] = existing
                if let jpeg = entry?.jpeg { loadMergedThumbnail(id, key: key, url: jpeg) }
            }
            return id
        }
        let reference = referenceFrame(ids).flatMap { shots[$0] }
        var shot = Shot(id: id, raw: first.raw, date: first.date, key: key)
        shot.mergedFrom = ids
        shot.previewURL = entry?.jpeg
        // The reference frame's thumbnail stands in until the merged one decodes (or while
        // a pruned merge is rebuilt).
        shot.thumbnail = reference?.thumbnail
        shot.exposure = reference?.exposure
        shots[id] = shot
        if let jpeg = entry?.jpeg { loadMergedThumbnail(id, key: key, url: jpeg) }
        // Selected but not yet saved (e.g. cut off by an unplug): carry on.
        if picks.contains(key), saved[key] == nil { saves.save([id]) }
        return id
    }

    /// Finds a finished merge on disk off the main actor (once per bracket), then shows it.
    private func lookUpMerge(_ ids: [String]) {
        let key = mergeKey(ids), name = mergedID(ids), cache = mergeCache
        guard mergeLookups.insert(key).inserted else { return }
        Task {
            guard let entry = await Background.decode({ cache.entry(key: key, name: name) }) else { return }
            mergeEntries[key] = entry
            if order.contains(ids[0]) { regroup() }
        }
    }

    private func loadMergedThumbnail(_ id: String, key: String, url: URL) {
        Task {
            let thumb = await Background.decode { ImageLoading.thumbnail(at: url, maxPixelSize: 360) }
            if let thumb { update(id, key: key) { $0.thumbnail = UIImage(cgImage: thumb) } }
        }
    }

    /// Starts merging a bracket (the Merge button). Progress and failures are in `merging`;
    /// when done the HDR frame appears in its moment.
    func merge(_ ids: [String]) {
        Task { _ = await mergedEntry(ids) }
    }

    /// The bracket's merged DNG and JPEG: cached, or merged now (shared by concurrent callers).
    /// Downloads the RAFs (waiting out an unplug), then decodes and merges them on the RAW
    /// queue: about 10 s on a Mac, longer on the phone.
    func mergedEntry(_ ids: [String]) async -> MergeCache.Entry? {
        let key = mergeKey(ids), name = mergedID(ids)
        let cache = mergeCache
        if let entry = mergeEntries[key] { return entry }
        if let entry = await Background.decode({ cache.entry(key: key, name: name) }) {
            mergeEntries[key] = entry
            return entry
        }
        if let running = mergeTasks[key] { return await running.value }
        let task = Task { [weak self] () -> MergeCache.Entry? in
            guard let self else { return nil }
            return await self.runMerge(ids, key: key, name: name)
        }
        mergeTasks[key] = task
        let entry = await task.value
        if mergeTasks[key] == task { mergeTasks[key] = nil }
        return entry
    }

    private func runMerge(_ ids: [String], key: String, name: String) async -> MergeCache.Entry? {
        let started = Date()
        func fail(_ reason: String) -> MergeCache.Entry? {
            merging[key] = .failed(reason)
            camera.record("HDR \(name) failed: \(reason)")
            return nil
        }
        // Work from hard links in our own folder: the RAF cache keeps only a few files and
        // other downloads may prune these mid-merge.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Merge-\(key)", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var raws: [URL] = []
        for (i, id) in ids.enumerated() {
            merging[key] = .running("Downloading \(i + 1) of \(ids.count)")
            guard let cached = await rawURL(id) else {
                return Task.isCancelled ? nil : fail("Couldn't download \(id)")
            }
            let link = work.appendingPathComponent(cached.lastPathComponent)
            guard (try? FileManager.default.linkOrCopy(cached, to: link)) != nil else { return fail("Couldn't copy \(id)") }
            raws.append(link)
        }
        let previews = ids.map { shots[$0]?.previewURL }
        let folder = mergeCache.folder(key: key)
        let sources = raws
        merging[key] = .running("Merging")
        let report: @Sendable (String) -> Void = { [weak self] step in
            Task { @MainActor in
                if case .running = self?.merging[key] { self?.merging[key] = .running(step) }
            }
        }
        let result = await Background.raw { () -> Result<HDRPipeline.Output, Error> in
            Result { try HDRPipeline.run(raws: sources, previews: previews, name: name, into: folder, progress: report) }
        }
        switch result {
        case .failure(let error):
            try? FileManager.default.removeItem(at: folder)
            return fail(error.localizedDescription)
        case .success(let output):
            merging[key] = nil
            output.report.forEach { camera.record("HDR \(name): \($0)") }
            camera.record(String(format: "HDR %@: done in %.1f s", name, Date().timeIntervalSince(started)))
            knownMerges.insert(key)
            UserDefaults.standard.set(Array(knownMerges), forKey: Self.mergesKey)
            let entry = MergeCache.Entry(dng: output.dng, jpeg: output.jpeg)
            mergeEntries[key] = entry
            let cache = mergeCache
            Task {
                await Background.decode { cache.prune() }
                // Some may be gone now: forget them all and look them up again.
                mergeEntries = mergeEntries.filter { $0.key == key }
                mergeLookups = [key]
            }
            // The shot picks up the new files (or appears, for a first merge).
            if order.contains(ids[0]) { regroup() }
            return entry
        }
    }

    private func distance(_ a: Shot, _ b: Shot) -> Float? {
        let key = "\(a.key)|\(b.key)"
        if let cached = distanceCache[key] { return cached }
        guard let pa = a.print, let pb = b.print, let d = pa.distance(to: pb) else { return nil }
        distanceCache[key] = d
        return d
    }

    /// The moment as it is now: a viewer keeps the ids it was opened with, but merging adds
    /// an HDR frame (and regrouping may change it). Falls back to `ids`.
    func liveMoment(_ ids: [String]) -> [String] {
        guard let first = ids.first else { return ids }
        return moments.first { $0.contains(first) } ?? ids
    }

    /// "HDR" for a moment with a merged frame, "Bracket" for one with an unmerged bracket.
    func bracketLabel(of ids: [String]) -> String? {
        if ids.contains(where: { shots[$0]?.isMerged == true }) { return "HDR" }
        return ids.contains { bracketOf[$0] != nil } ? "Bracket" : nil
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
        // Brackets skip ranking: their dark and bright frames would be flagged as flawed.
        let candidates = ids.filter { shots[$0]?.isRankable == true && bracket(of: $0) == nil }
        let scores = candidates.compactMap { shots[$0]?.score }
        guard !candidates.isEmpty, scores.count == candidates.count else { return nil }
        let ranked = BestShot.rank(scores)
        let best = candidates.count > 1 ? BestShot.bestIndex(ranked).map { candidates[$0] } : nil
        return Ranking(breakdowns: Dictionary(uniqueKeysWithValues: zip(candidates, ranked)), suggested: best)
    }

    /// The frame that stands for a moment: the first selected, else the suggestion, else the
    /// middle frame that loaded (so the feed doesn't flicker or lead with a failed frame).
    func hero(of ids: [String], ranking: Ranking? = nil) -> String {
        if let pick = selected(in: ids).first ?? (ranking ?? self.ranking(of: ids))?.suggested { return pick }
        // A bracket's merged frame, else its middle exposure.
        if let merged = ids.first(where: { shots[$0]?.isMerged == true }) { return merged }
        if let bracket = ids.lazy.compactMap({ self.bracket(of: $0) }).first,
           let reference = referenceFrame(bracket) { return reference }
        let usable = ids.filter { shots[$0]?.error == nil }
        let pool = usable.isEmpty ? ids : usable
        return pool[pool.count / 2]
    }

    // MARK: Selection

    func isSelected(_ id: String) -> Bool {
        shots[id].map { picks.contains($0.key) } ?? false
    }

    /// Selected frames among `ids`, in their order.
    func selected(in ids: [String]) -> [String] {
        ids.filter(isSelected)
    }

    func isSaved(_ id: String) -> Bool {
        shots[id].map { saved[$0.key] != nil } ?? false
    }

    func selectionState(_ id: String) -> SelectionCircle.Kind {
        isSaved(id) ? .saved : isSelected(id) ? .selected : .unselected
    }

    /// Selecting saves to Photos in the background. Deselecting drops an unsaved frame from
    /// the queue, or asks iOS to delete a saved one from Photos (and stays selected if the
    /// owner keeps it), so selection always matches what's in Photos.
    func toggleSelection(_ id: String) {
        guard let key = shots[id]?.key else { return }
        guard picks.contains(key) else {
            picks.insert(key)
            persistPicks()
            saves.save([id])
            return
        }
        if let asset = saved[key] {
            Task {
                guard await PhotoSaver.delete(assetID: asset) else { return }
                saved[key] = nil
                savedFormats[key] = nil
                UserDefaults.standard.set(savedFormats, forKey: Self.savedFormatsKey)
                UserDefaults.standard.set(saved, forKey: Self.savedKey)
                picks.remove(key)
                persistPicks()
            }
        } else {
            picks.remove(key)
            persistPicks()
            saves.unqueue(key: key)
        }
    }

    /// A save finished. Also (re)selects it: it's in Photos now, even if it was deselected
    /// while being written.
    func markSaved(key: String, assetID: String, format: SaveFormat) {
        saved[key] = assetID
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
        savedFormats[key] = format.rawValue
        UserDefaults.standard.set(savedFormats, forKey: Self.savedFormatsKey)
        if picks.insert(key).inserted { persistPicks() }
    }

    private func persistPicks() {
        UserDefaults.standard.set(Array(picks), forKey: Self.picksKey)
    }

    /// Selected frames on the card not yet in Photos (e.g. cut off by an earlier unplug),
    /// in time order.
    private func unsavedSelections() -> [String] {
        shots.values
            .filter { picks.contains($0.key) && saved[$0.key] == nil }
            .sorted { ($0.date ?? .distantPast, $0.id) < ($1.date ?? .distantPast, $1.id) }
            .map(\.id)
    }

    /// The frame to compare `top` against: the best-ranked other frame, else the next one in
    /// time. Nil for single frames.
    func challenger(for top: String, in ids: [String], ranking: Ranking?) -> String? {
        let others = ids.filter { $0 != top }
        guard !others.isEmpty else { return nil }
        if let totals = ranking?.breakdowns.mapValues(\.total),
           let best = others.max(by: { (totals[$0] ?? -1) < (totals[$1] ?? -1) }) {
            return best
        }
        let i = ids.firstIndex(of: top) ?? 0
        return i + 1 < ids.count ? ids[i + 1] : ids[i - 1]
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
