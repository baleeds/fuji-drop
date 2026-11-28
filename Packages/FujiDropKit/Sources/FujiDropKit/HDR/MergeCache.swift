import Foundation

/// Merged HDR outputs (DNG + JPEG), one folder per bracket, keyed by the bracket's source
/// files. Unlike `RawCache` it survives sessions (a merge takes tens of seconds and a merged
/// frame may be selected but not yet saved), but it's bounded: the least recently used
/// folders beyond `keep` are removed, and a missing merge is rebuilt from the RAFs.
public struct MergeCache: Sendable {
    public static let defaultKeep = 8
    /// Bumped when the merge itself changes, so older outputs aren't reused (they're pruned
    /// like any other). 2: reference-anchored weights (no blending of moving subjects).
    /// 3: the JPEG's colour matched to the camera's JPEG (it read bluer).
    public static let version = 3

    public struct Entry: Sendable, Equatable {
        public var dng: URL
        public var jpeg: URL

        public init(dng: URL, jpeg: URL) {
            self.dng = dng
            self.jpeg = jpeg
        }
    }

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Merges", isDirectory: true)
    }

    /// A stable key for a bracket from its frames' keys (camera/name-size): FNV-1a 64, hex.
    /// Stable across launches, unlike `Hasher`.
    public static func key(for sourceKeys: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in sourceKeys.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    public func folder(key: String) -> URL {
        directory.appendingPathComponent("\(key)-v\(Self.version)", isDirectory: true)
    }

    /// The finished merge, marking it as recently used. Nil if missing or incomplete.
    public func entry(key: String, name: String, now: Date = Date()) -> Entry? {
        let dir = folder(key: key)
        let e = Entry(dng: dir.appendingPathComponent("\(name).DNG"), jpeg: dir.appendingPathComponent("\(name).JPG"))
        guard FileManager.default.fileExists(atPath: e.dng.path),
              FileManager.default.fileExists(atPath: e.jpeg.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dir.path)
        return e
    }

    /// Removes merges made by an older version, then all but the `keep` most recently used.
    public func prune(keep: Int = MergeCache.defaultKeep) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isDirectory == true else { return nil }
                guard url.lastPathComponent.hasSuffix("-v\(Self.version)") else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
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
}
