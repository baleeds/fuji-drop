import FujiDropKit
import Foundation
import Photos

/// Saves picks to Photos one at a time in the background: download the RAF (shared with
/// compare's cache), render a full-size JPEG on the phone, then save both as one RAW+JPEG
/// asset with the RAF as the editing base. About 3 s per pick; less if compare already
/// downloaded the RAF.
///
/// Survives unplugging: a pick whose RAF can't download waits for the camera to come back,
/// then carries on. Ending the session (or a different camera) clears the queue.
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

        var state = State.running
        var total = 0
        /// Attempted so far (saved or failed).
        var done = 0
        var current: String?
        var failures: [Failure] = []

        var savedCount: Int { done - failures.count }
    }

    struct Failure: Equatable {
        let id: String
        let reason: String
    }

    private struct Item: Equatable {
        let id: String
        let key: String
    }

    private enum SaveError: LocalizedError {
        case notOnCard, downloadFailed, sessionEnded, renderFailed(String)
        var errorDescription: String? {
            switch self {
            case .notOnCard: return "No longer on the card"
            case .downloadFailed: return "Couldn't download the RAW file"
            case .sessionEnded: return "Camera disconnected"
            case .renderFailed(let reason): return reason
            }
        }
    }

    /// Nil when there's nothing to show.
    @Published private(set) var progress: Progress?

    private weak var model: ImportModel?
    private var pending: [Item] = []
    private var worker: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(model: ImportModel) {
        self.model = model
    }

    var isRunning: Bool { progress?.state == .running }

    /// Queues the given picks (skipping ones already saved or queued) and starts saving.
    func save(_ ids: [String]) {
        guard let model else { return }
        let items = ids.compactMap { id -> Item? in
            guard let shot = model.shots[id], model.saved[shot.key] == nil else { return nil }
            return Item(id: id, key: shot.key)
        }
        .filter { !pending.contains($0) }
        guard !items.isEmpty else { return }
        hideTask?.cancel()

        if progress?.state == .running {
            progress?.total += items.count
        } else {
            progress = Progress(total: items.count)
        }
        pending += items
        startIfNeeded()
    }

    /// After Photos access was granted (blocked), carry on with what's left.
    func resume() {
        guard progress?.state == .blocked else { return }
        progress?.state = .running
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard worker == nil, progress?.state == .running, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
            // Items queued while a stopped run was winding down.
            self?.startIfNeeded()
        }
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

    func dismiss() {
        guard progress?.state != .running else { return }
        hideTask?.cancel()
        progress = nil
    }

    /// The session ended: drop everything (saved photos stay saved).
    func reset() {
        worker?.cancel()
        worker = nil
        hideTask?.cancel()
        pending = []
        progress = nil
    }

    // MARK: Work

    private func run() async {
        while !Task.isCancelled, let item = pending.first {
            progress?.current = item.id
            do {
                try await save(item)
            } catch PhotoSaver.SaveError.notAuthorized {
                // Nothing else will save either; keep the queue for after it's allowed.
                progress?.state = .blocked
                progress?.current = nil
                model?.camera.record("Save: Photos access not granted.")
                return
            } catch is CancellationError {
                break
            } catch {
                progress?.failures.append(Failure(id: item.id, reason: error.localizedDescription))
                model?.camera.record("Save \(item.id) failed: \(error.localizedDescription)")
            }
            pending.removeAll { $0 == item }
            progress?.done += 1
        }
        progress?.current = nil
        guard progress?.state == .running else { return }
        progress?.state = .finished
        // A clean run hides itself; failures stay until dismissed or retried.
        if progress?.failures.isEmpty == true {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.progress = nil
            }
        }
    }

    private func save(_ item: Item) async throws {
        guard let model else { throw SaveError.sessionEnded }
        guard let shot = model.shots[item.id], shot.key == item.key else { throw SaveError.notOnCard }
        let started = Date()

        let raw = try await rawFile(item)
        try Task.checkCancellation()

        // Render the full-size JPEG off the main actor, in its own folder.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Renders", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendered = await Background.raw { () -> Result<URL, Error> in
            Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                return try RAWRenderer.renderJPEG(from: raw, into: folder)
            }
        }
        let jpeg: URL
        switch rendered {
        case .success(let url): jpeg = url
        case .failure(let error): throw SaveError.renderFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let assetID = try await PhotoSaver.savePair(jpeg: jpeg, raw: raw, filename: item.id,
                                                    creationDate: shot.date)
        model.markSaved(key: item.key, assetID: assetID)
        model.camera.record(String(format: "Saved %@ to Photos in %.1f s", item.id, Date().timeIntervalSince(started)))
    }

    /// The pick's RAF, downloading it if needed. While the camera is unplugged this waits for
    /// it to come back instead of failing.
    private func rawFile(_ item: Item) async throws -> URL {
        guard let model else { throw SaveError.sessionEnded }
        while true {
            if let url = await model.rawURL(item.id) { return url }
            try Task.checkCancellation()
            switch model.connection {
            case .connected:
                throw SaveError.downloadFailed
            case .none:
                throw SaveError.sessionEnded
            case .reconnecting:
                for await state in model.$connection.values where state != .reconnecting { break }
                try Task.checkCancellation()
                guard model.shots[item.id]?.key == item.key else { throw SaveError.notOnCard }
            }
        }
    }
}
