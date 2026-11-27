import Foundation

/// Full RAF files downloaded for 100 % comparison (and reused when saving a pick).
/// Keyed by file name plus size like `PreviewCache`. Small: only the most recent few files are
/// kept (about 33 MB each), and the app clears it when the camera disconnects.
public struct RawCache: Sendable {
    public static let defaultKeep = 6

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAF", isDirectory: true)
    }

    /// Where downloads land before `adopt` renames them (the camera picks the file name).
    public var incoming: URL { directory.appendingPathComponent("Incoming", isDirectory: true) }

    /// Keeps the .RAF extension: Core Image picks the RAW decoder from it.
    public func url(name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size).RAF")
    }

    /// Returns the cached RAF, marking it as recently used.
    public func cachedURL(name: String, size: Int64, now: Date = Date()) -> URL? {
        let u = url(name: name, size: size)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
        return u
    }

    /// Moves a downloaded file into the cache under its key.
    @discardableResult
    public func adopt(_ downloaded: URL, name: String, size: Int64, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = url(name: name, size: size)
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.moveItem(at: downloaded, to: u)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: u.path)
        return u
    }

    /// Removes all but the `keep` most recently used files.
    public func prune(keep: Int = RawCache.defaultKeep) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
                return (url, v.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in files.dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
