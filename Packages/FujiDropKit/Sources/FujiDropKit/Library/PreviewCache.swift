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

    public func url(name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size).jpg")
    }

    /// Returns the cached preview, marking it as recently used.
    public func cachedURL(name: String, size: Int64, now: Date = Date()) -> URL? {
        let u = url(name: name, size: size)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
        return u
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
        return Usage(files: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes })
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

        func remove(_ e: Entry) {
            guard (try? FileManager.default.removeItem(at: e.url)) != nil else { return }
            removed.files += 1
            removed.bytes += e.bytes
            total -= e.bytes
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        while let oldest = entries.first, oldest.used < cutoff || total > maxBytes {
            remove(oldest)
            entries.removeFirst()
        }
        return PruneResult(removed: removed, remaining: Usage(files: entries.count, bytes: total))
    }

    @discardableResult
    public func clear() -> Usage {
        prune(maxBytes: 0, maxAge: 0).removed
    }

    private struct Entry {
        let url: URL
        let bytes: Int64
        let used: Date
    }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return Entry(url: url, bytes: Int64(v.fileSize ?? 0), used: v.contentModificationDate ?? .distantPast)
        }
    }
}
