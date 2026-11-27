import Foundation

/// On-disk cache of embedded RAF previews, so reconnecting the camera doesn't re-read them.
/// Keyed by file name plus file size, which distinguishes reused DSCF numbers across cards.
public struct PreviewCache: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Previews", isDirectory: true)
    }

    public func url(name: String, size: Int64) -> URL {
        directory.appendingPathComponent("\(name)-\(size).jpg")
    }

    public func cachedURL(name: String, size: Int64) -> URL? {
        let u = url(name: name, size: size)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    @discardableResult
    public func store(_ data: Data, name: String, size: Int64) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let u = url(name: name, size: size)
        try data.write(to: u, options: .atomic)
        return u
    }
}
