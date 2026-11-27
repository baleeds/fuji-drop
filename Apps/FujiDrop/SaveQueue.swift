import FujiDropKit
import Foundation
import Photos
import UIKit

/// Saves picks to Photos one at a time in the background: get the RAF (shared with
/// compare's cache), render a full-size JPEG on the phone, then save both as one RAW+JPEG
/// asset with the RAF as the editing base. About 3 s per pick; less if compare already
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
    private var worker: Task<Void, Never>?

    init(model: ImportModel) {
        self.model = model
    }

    /// Queues the given picks (skipping ones already saved or queued) and starts saving.
    func save(_ ids: [String]) {
        let items = ids.compactMap { id -> Item? in
            guard let shot = model.shots[id], !model.isSaved(id) else { return nil }
            return Item(id: id, key: shot.key)
        }
        .filter { !pending.contains($0) }
        guard !items.isEmpty else { return }

        if progress?.state == .running {
            progress?.total += items.count
        } else {
            progress = Progress(total: items.count)
        }
        pending += items
        startIfNeeded()
    }

    /// Stops after the current photo; the rest stay unsaved.
    func cancel() {
        worker?.cancel()
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
        progress = nil
    }

    /// The session ended: drop everything (saved photos stay saved).
    func reset() {
        worker?.cancel()
        worker = nil
        pending = []
        progress = nil
    }

    // MARK: Work

    private func startIfNeeded() {
        guard worker == nil, progress?.state == .running, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
            // Items queued while a stopped run was winding down.
            self?.startIfNeeded()
        }
    }

    private func run() async {
        while !Task.isCancelled, let item = pending.first {
            progress?.current = model.shots[item.id]?.thumbnail
            do {
                try await save(item)
            } catch PhotoSaver.SaveError.notAuthorized {
                // Nothing else will save either; keep the queue for after it's allowed.
                progress?.state = .blocked
                progress?.current = nil
                model.camera.record("Save: Photos access not granted.")
                return
            } catch is CancellationError {
                break
            } catch {
                progress?.failures.append(Failure(id: item.id, reason: error.localizedDescription))
                model.camera.record("Save \(item.id) failed: \(error.localizedDescription)")
            }
            pending.removeAll { $0 == item }
            progress?.done += 1
        }
        progress?.current = nil
        // Finished only if nothing new was queued (a cancelled run may be winding down while a
        // new save starts).
        if progress?.state == .running, pending.isEmpty { progress?.state = .finished }
    }

    private func save(_ item: Item) async throws {
        let started = Date()
        // Waits out an unplug; nil means it failed or the file is gone.
        guard let raw = await model.rawURL(item.id) else {
            try Task.checkCancellation()
            throw model.shots[item.id]?.key == item.key ? SaveError.downloadFailed : SaveError.notOnCard
        }
        try Task.checkCancellation()
        guard let shot = model.shots[item.id], shot.key == item.key else { throw SaveError.notOnCard }

        // Fetch the next pick's RAF while this one renders (camera and CPU in parallel).
        if let next = pending.dropFirst().first {
            Task { [model] in _ = await model.rawURL(next.id) }
        }

        // Render the full-size JPEG off the main actor, in its own folder, reusing compare's
        // decode when there is one.
        let decoded = PreviewImageLoader.shared.cachedFullResolution(raw: raw)?.cgImage
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Renders", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = try await Background.raw { () -> Result<URL, Error> in
            Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try RAWRenderer.renderJPEG(from: raw, image: decoded, into: folder)
            }
        }.get()
        try Task.checkCancellation()

        let assetID = try await PhotoSaver.savePair(jpeg: jpeg, raw: raw, creationDate: shot.date)
        model.markSaved(key: item.key, assetID: assetID)
        model.camera.record(String(format: "Saved %@ to Photos in %.1f s", item.id, Date().timeIntervalSince(started)))
    }
}
