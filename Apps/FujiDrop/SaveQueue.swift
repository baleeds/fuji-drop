import FujiDropKit
import Foundation
import Photos
import UIKit

/// Saves selections to Photos one at a time in the background: get the RAF (shared with
/// compare's cache), render a full-size JPEG on the phone, then save both as one RAW+JPEG
/// asset with the RAF as the editing base. A merged HDR frame saves its DNG and the JPEG the
/// merge rendered the same way (the DNG is the editing base). About 3 s per pick; less if compare already
/// downloaded and decoded the RAF. The next pick's RAF downloads while this one renders.
///
/// Survives unplugging: `ImportModel.rawURL` waits for the camera to come back. Ending the
/// session (or a different camera) clears the queue.
@MainActor
final class SaveQueue: ObservableObject {
    struct Progress: Equatable {
        enum State: Equatable {
            case running
            case finished
            case stopped
            /// Photos access denied: nothing can save until it's allowed in Settings.
            case blocked
        }

        /// What the bar shows: the state, with a finished run split by whether all saved.
        enum Phase: Equatable { case saving, done, partial, stopped, blocked }

        var state = State.running
        var total = 0
        /// Attempted so far (saved or failed).
        var done = 0
        /// The photo being saved, for the bar.
        var current: UIImage?
        var failures: [Failure] = []

        var savedCount: Int { done - failures.count }
        /// 1-based position of the photo being saved.
        var position: Int { min(done + 1, total) }

        var phase: Phase {
            switch state {
            case .running: return .saving
            case .finished: return failures.isEmpty ? .done : .partial
            case .stopped: return .stopped
            case .blocked: return .blocked
            }
        }
    }

    struct Failure: Equatable {
        let id: String
        let reason: String
    }

    private struct Item: Equatable {
        let id: String
        /// The exact file queued, so a reused DSCF number on a swapped card isn't saved instead.
        let key: String
    }

    private enum SaveError: LocalizedError {
        case notOnCard, downloadFailed
        var errorDescription: String? {
            switch self {
            case .notOnCard: return "No longer on the card"
            case .downloadFailed: return "Couldn't download the RAW file"
            }
        }
    }

    /// Nil when there's nothing to show.
    @Published private(set) var progress: Progress?

    /// The model owns this queue and resets it before going away.
    private unowned let model: ImportModel
    private var pending: [Item] = []
    /// Keys being saved right now, across runs: a stopped run may still be finishing one, and
    /// it mustn't be queued (and saved) again meanwhile.
    private var inFlight: Set<String> = []
    private var worker: Task<Void, Never>?
    private var prefetch: Task<Void, Never>?
    /// Bumped whenever a run is stopped or replaced; a run that finishes late only touches
    /// state if it's still current.
    private var generation = 0

    init(model: ImportModel) {
        self.model = model
    }

    /// Queues the given selections (skipping ones saved, queued or being saved) and starts.
    func save(_ ids: [String]) {
        let items = ids.compactMap { id -> Item? in
            guard let shot = model.shots[id], !model.isSaved(id), !inFlight.contains(shot.key) else { return nil }
            return Item(id: id, key: shot.key)
        }
        .filter { !pending.contains($0) }
        guard !items.isEmpty else { return }
        pending += items

        switch progress?.state {
        case .running:
            progress?.total += items.count
        case .blocked:
            progress?.total = (progress?.done ?? 0) + pending.count
        default:
            // Count everything still to do, including items a blocked run left behind.
            progress = Progress(total: pending.count)
        }
        startIfNeeded()
    }

    /// Drops a deselected, unsaved frame from the queue.
    func unqueue(key: String) {
        // Already being written: it'll land in Photos (and be selected again) regardless.
        guard !inFlight.contains(key), let index = pending.firstIndex(where: { $0.key == key }) else { return }
        pending.remove(at: index)
        progress?.total -= 1
        if progress?.total == progress?.done, progress?.state == .running {
            progress?.state = .finished
        }
    }

    /// Stops after the current photo; the rest stay unsaved (and selected).
    func cancel() {
        stopRun()
        pending = []
        if progress?.state == .running { progress?.state = .stopped }
    }

    func retryFailed() {
        let ids = progress?.failures.map(\.id) ?? []
        progress = nil
        save(ids)
    }

    /// After Photos access was granted (blocked), carry on with what's left.
    func resume() {
        guard progress?.state == .blocked else { return }
        progress?.state = .running
        startIfNeeded()
    }

    func dismiss() {
        guard progress?.state != .running else { return }
        if progress?.state == .blocked { pending = [] }
        progress = nil
    }

    /// The session ended: drop everything (saved photos stay saved).
    func reset() {
        stopRun()
        pending = []
        progress = nil
    }

    // MARK: Work

    private func stopRun() {
        generation += 1
        worker?.cancel()
        worker = nil
        prefetch?.cancel()
        prefetch = nil
    }

    private func startIfNeeded() {
        guard worker == nil, progress?.state == .running, !pending.isEmpty else { return }
        generation += 1
        let run = generation
        worker = Task { [weak self] in
            await self?.run(run)
            guard let self, self.generation == run else { return }
            self.worker = nil
            self.startIfNeeded()
        }
    }

    private func run(_ run: Int) async {
        while !Task.isCancelled, generation == run, let item = pending.first {
            progress?.current = model.shots[item.id]?.thumbnail
            inFlight.insert(item.key)
            var failure: String?
            do {
                try await save(item)
            } catch PhotoSaver.SaveError.notAuthorized {
                inFlight.remove(item.key)
                guard generation == run else { return }
                // Nothing else will save either; keep the queue for after it's allowed.
                progress?.state = .blocked
                progress?.current = nil
                model.camera.record("Save: Photos access not granted.")
                return
            } catch is CancellationError {
                inFlight.remove(item.key)
                return
            } catch {
                failure = error.localizedDescription
                model.camera.record("Save \(item.id) failed: \(error.localizedDescription)")
            }
            inFlight.remove(item.key)
            // A stopped or replaced run doesn't touch the new run's queue or counts.
            guard generation == run else { return }
            if let failure { progress?.failures.append(Failure(id: item.id, reason: failure)) }
            pending.removeAll { $0 == item }
            progress?.done += 1
        }
        guard generation == run else { return }
        progress?.current = nil
        if progress?.state == .running, pending.isEmpty { progress?.state = .finished }
    }

    private func save(_ item: Item) async throws {
        // Saved meanwhile (e.g. by a stopped run finishing it): nothing to do.
        guard !model.isSaved(item.id) || model.shots[item.id]?.key != item.key else { return }
        let started = Date()
        // Waits out an unplug; nil means it failed or the file is gone.
        guard let cached = await model.rawURL(item.id) else {
            try Task.checkCancellation()
            throw model.shots[item.id]?.key == item.key ? SaveError.downloadFailed : SaveError.notOnCard
        }
        try Task.checkCancellation()
        guard let shot = model.shots[item.id], shot.key == item.key else { throw SaveError.notOnCard }

        // Work from a hard link in our own folder: the RAF cache keeps only a few files and
        // other downloads may prune this one mid-save. Same name, so Photos gets DSCF1234.RAF.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Renders", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent(cached.lastPathComponent)
        do {
            try FileManager.default.linkItem(at: cached, to: raw)
        } catch {
            try FileManager.default.copyItem(at: cached, to: raw)
        }

        // Fetch the next selection's RAF while this one renders (camera and CPU in parallel).
        prefetch?.cancel()
        if let next = pending.dropFirst().first {
            prefetch = Task { [model] in _ = await model.rawURL(next.id) }
        }

        // A merged HDR frame already has its JPEG, rendered from the DNG by the merge.
        let mergedJPEG = shot.isMerged ? cached.deletingPathExtension().appendingPathExtension("JPG") : nil
        if let mergedJPEG {
            let jpeg = folder.appendingPathComponent(mergedJPEG.lastPathComponent)
            if (try? FileManager.default.linkItem(at: mergedJPEG, to: jpeg)) == nil {
                try FileManager.default.copyItem(at: mergedJPEG, to: jpeg)
            }
            let assetID = try await PhotoSaver.savePair(jpeg: jpeg, raw: raw, creationDate: shot.date)
            model.markSaved(key: item.key, assetID: assetID)
            model.camera.record(String(format: "Saved %@ (HDR DNG) to Photos in %.1f s", item.id, Date().timeIntervalSince(started)))
            return
        }

        // Render the full-size JPEG off the main actor, reusing compare's decode if any.
        // Either way the brightness matches the camera's own JPEG (see RAWRenderer).
        let decoded = PreviewImageLoader.shared.cachedFullResolution(raw: cached)?.cgImage
        let preview = shot.previewURL
        let jpeg = try await Background.raw { () -> Result<URL, Error> in
            Result {
                let reference = decoded == nil ? preview.flatMap { ImageLoading.thumbnail(at: $0, maxPixelSize: 256) } : nil
                return try RAWRenderer.renderJPEG(from: raw, image: decoded, matching: reference, into: folder)
            }
        }.get()
        try Task.checkCancellation()

        let assetID = try await PhotoSaver.savePair(jpeg: jpeg, raw: raw, creationDate: shot.date)
        model.markSaved(key: item.key, assetID: assetID)
        model.camera.record(String(format: "Saved %@ to Photos in %.1f s", item.id, Date().timeIntervalSince(started)))
    }
}
