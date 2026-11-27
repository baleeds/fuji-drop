import Foundation

/// Full RAF files downloaded for 100 % comparison and for saving picks. Small: only the most
/// recent few files are kept (about 33 MB each), and the app clears it when a session ends.
///
/// Each file lives in a folder named by its key (name plus size, like `PreviewCache`, so a
/// reused DSCF number on another card is a different entry) under its own camera file name:
/// `RAF/DSCF1234-33512448/DSCF1234.RAF`. So anything made from it (a rendered JPEG, the
/// resources saved to Photos) gets the real name without renaming.
public struct RawCache: Sendable {
    public static let defaultKeep = 6

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RAF", isDirectory: true)
    }

    /// Where downloads land before `adopt` moves them into place.
    public var incoming: URL { directory.appendingPathComponent("Incoming", isDirectory: true) }

    private func folder(name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size)", isDirectory: true)
    }

    /// Keeps the .RAF extension: Core Image picks the RAW decoder from it.
    public func url(name: String, size: Int64) -> URL {
        folder(name: name, size: size).appendingPathComponent("\(name).RAF")
    }

    /// Returns the cached RAF, marking it as recently used.
    public func cachedURL(name: String, size: Int64, now: Date = Date()) -> URL? {
        let u = url(name: name, size: size)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now],
                                               ofItemAtPath: folder(name: name, size: size).path)
        return u
    }

    /// Moves a downloaded file into the cache under its key.
    @discardableResult
    public func adopt(_ downloaded: URL, name: String, size: Int64, now: Date = Date()) throws -> URL {
        let dir = folder(name: name, size: size)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = url(name: name, size: size)
        try FileManager.default.moveItem(at: downloaded, to: u)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dir.path)
        return u
    }

    /// Removes all but the `keep` most recently used files.
    public func prune(keep: Int = RawCache.defaultKeep) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.lastPathComponent != incoming.lastPathComponent }
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true else { return nil }
                return (url, v.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in entries.dropFirst(max(0, keep)) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Empties the cache at once (one rename) and returns the old folder for the caller to
    /// delete at leisure, so downloads starting right after never land in a folder that's
    /// being deleted. Nil if there was nothing to clear.
    public func detach() -> URL? {
        let trash = directory.deletingLastPathComponent()
            .appendingPathComponent("RAF-old-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.moveItem(at: directory, to: trash)) != nil else { return nil }
        return trash
    }
}
