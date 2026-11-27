import XCTest
@testable import FujiDropKit

final class RawCacheTests: XCTestCase {
    private var cache: RawCache!

    override func setUpWithError() throws {
        cache = RawCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RawCacheTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        cache.clear()
    }

    private func download(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: cache.incoming, withIntermediateDirectories: true)
        let u = cache.incoming.appendingPathComponent("\(name).RAF")
        try Data(name.utf8).write(to: u)
        return u
    }

    func testAdoptKeepsCameraFileNameUnderKeyFolder() throws {
        let u = try cache.adopt(try download("DSCF0001"), name: "DSCF0001", size: 42)
        XCTAssertEqual(u.lastPathComponent, "DSCF0001.RAF")
        XCTAssertEqual(u.deletingLastPathComponent().lastPathComponent, "DSCF0001-42")
        XCTAssertEqual(cache.cachedURL(name: "DSCF0001", size: 42), u)
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 43), "a different file reusing the number")
    }

    /// Clearing renames the folder away at once: a download right after gets a fresh folder,
    /// untouched by deleting the old files.
    func testDetachEmptiesAtOnceAndKeepsOldFilesForDeletion() throws {
        try cache.adopt(try download("DSCF0001"), name: "DSCF0001", size: 1)
        let old = try XCTUnwrap(cache.detach())
        defer { try? FileManager.default.removeItem(at: old) }
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("DSCF0001-1/DSCF0001.RAF").path))
        let fresh = try cache.adopt(try download("DSCF0002"), name: "DSCF0002", size: 2)
        try FileManager.default.removeItem(at: old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testPruneKeepsMostRecentlyUsed() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<4 {
            try cache.adopt(try download("DSCF000\(i)"), name: "DSCF000\(i)", size: 1,
                            now: t0.addingTimeInterval(Double(i)))
        }
        // Using the oldest makes it the newest.
        _ = cache.cachedURL(name: "DSCF0000", size: 1, now: t0.addingTimeInterval(10))
        cache.prune(keep: 2)
        XCTAssertNotNil(cache.cachedURL(name: "DSCF0000", size: 1))
        XCTAssertNotNil(cache.cachedURL(name: "DSCF0003", size: 1))
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 1))
        XCTAssertNil(cache.cachedURL(name: "DSCF0002", size: 1))
    }
}
