import Foundation

/// On-disk cache of embedded RAF previews, so reconnecting the camera doesn't re-read them.
/// Keyed by file name plus file size, which distinguishes reused DSCF numbers across cards.
///
/// Lives in Caches (iOS may purge it under storage pressure). `prune` keeps it bounded:
/// entries unused for `maxAge` are removed, then least-recently-used entries until the
/// total is under `maxBytes`. A cache hit refreshes the entry's date.
public struct PreviewCache: Sendable {
    public static let defaultMaxBytes: Int64 = 500_000_000
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 3600

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Previews", isDirectory: true)
    }

    /// A cache for one camera's previews: a subfolder, so each body keeps its own files.
    /// Pruning, usage and clearing on the parent cover every camera's folder.
    public func scoped(to camera: String) -> PreviewCache {
        let safe = camera.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return PreviewCache(directory: directory.appendingPathComponent(String(safe), isDirectory: true))
    }

    public func url(name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size).jpg")
    }

    /// Analysis saved next to a preview (see `SavedAnalysis`), so reconnecting doesn't redo it.
    /// Trimmed with its preview; on its own once it's the oldest entry.
    public enum Sidecar: String, CaseIterable, Sendable {
        case score, print
    }

    public func sidecarURL(_ kind: Sidecar, name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size).\(kind.rawValue)")
    }

    /// A saved sidecar, marking it as recently used.
    public func readSidecar(_ kind: Sidecar, name: String, size: Int64, now: Date = Date()) -> Data? {
        let u = sidecarURL(kind, name: name, size: size)
        guard let data = try? Data(contentsOf: u) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
        return data
    }

    public func writeSidecar(_ data: Data, _ kind: Sidecar, name: String, size: Int64) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: sidecarURL(kind, name: name, size: size), options: .atomic)
    }

    /// Returns the cached preview, marking it as recently used.
    public func cachedURL(name: String, size: Int64, now: Date = Date()) -> URL? {
        let u = url(name: name, size: size)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
        return u
    }

    /// Drops one preview, e.g. one that turned out not to decode, so it's read again, with
    /// its saved analysis.
    public func remove(name: String, size: Int64) {
        try? FileManager.default.removeItem(at: url(name: name, size: size))
        for kind in Sidecar.allCases { try? FileManager.default.removeItem(at: sidecarURL(kind, name: name, size: size)) }
    }

    @discardableResult
    public func store(_ data: Data, name: String, size: Int64) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = url(name: name, size: size)
        try data.write(to: u, options: .atomic)
        return u
    }

    // MARK: Housekeeping

    public struct Usage: Equatable, Sendable {
        /// Previews (saved analysis files aren't counted, but their bytes are).
        public var files: Int
        public var bytes: Int64

        public init(files: Int, bytes: Int64) {
            self.files = files
            self.bytes = bytes
        }
    }

    public struct PruneResult: Equatable, Sendable {
        public var removed: Usage
        public var remaining: Usage
    }

    public func usage() -> Usage {
        let entries = self.entries()
        return Usage(files: entries.filter(\.isPreview).count, bytes: entries.reduce(0) { $0 + $1.bytes })
    }

    @discardableResult
    public func prune(
        maxBytes: Int64 = PreviewCache.defaultMaxBytes,
        maxAge: TimeInterval = PreviewCache.defaultMaxAge,
        now: Date = Date()
    ) -> PruneResult {
        var entries = self.entries().sorted { $0.used < $1.used } // oldest first
        var removed = Usage(files: 0, bytes: 0)
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var gone = Set<URL>()

        func remove(_ e: Entry) {
            guard !gone.contains(e.url), (try? FileManager.default.removeItem(at: e.url)) != nil else { return }
            gone.insert(e.url)
            if e.isPreview { removed.files += 1 }
            removed.bytes += e.bytes
            total -= e.bytes
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        let byURL = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        while let oldest = entries.first, oldest.used < cutoff || total > maxBytes {
            remove(oldest)
            // A preview's analysis is no use without it.
            if oldest.isPreview {
                let base = oldest.url.deletingPathExtension()
                for kind in Sidecar.allCases {
                    if let sidecar = byURL[base.appendingPathExtension(kind.rawValue)] { remove(sidecar) }
                }
            }
            entries.removeFirst()
        }
        entries.removeAll { gone.contains($0.url) }
        return PruneResult(removed: removed,
                           remaining: Usage(files: entries.filter(\.isPreview).count, bytes: total))
    }

    @discardableResult
    public func clear() -> Usage {
        prune(maxBytes: 0, maxAge: 0).removed
    }

    private struct Entry {
        let url: URL
        let bytes: Int64
        let used: Date
        var isPreview: Bool { url.pathExtension == "jpg" }
    }

    /// Every cached file, including those in per-camera subfolders.
    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
        let urls = (enumerator?.allObjects as? [URL]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Entry(url: url, bytes: Int64(v.fileSize ?? 0), used: v.contentModificationDate ?? .distantPast)
        }
    }
}
