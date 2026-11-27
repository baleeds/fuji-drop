import FujiDropKit
import XCTest

final class MergeCacheTests: XCTestCase {
    func testKeyIsStableAndDependsOnEveryFile() {
        let keys = ["X-T1/DSCF1-1", "X-T1/DSCF2-2", "X-T1/DSCF3-3"]
        // Fixed value: must not change between launches (unlike Hasher).
        XCTAssertEqual(MergeCache.key(for: keys), MergeCache.key(for: keys))
        XCTAssertEqual(MergeCache.key(for: ["a"]), "af63dc4c8601ec8c")
        XCTAssertNotEqual(MergeCache.key(for: keys), MergeCache.key(for: ["X-T1/DSCF1-1", "X-T1/DSCF2-2", "X-T1/DSCF3-4"]))
    }

    func testEntryNeedsBothFilesAndPruneKeepsRecent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MergeCache(directory: dir)
        defer { cache.clear() }
        func make(_ key: String, _ age: TimeInterval, jpeg: Bool = true) throws {
            let f = cache.folder(key: key)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            try Data([1]).write(to: f.appendingPathComponent("X-HDR.DNG"))
            if jpeg { try Data([1]).write(to: f.appendingPathComponent("X-HDR.JPG")) }
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: f.path)
        }
        try make("old", 300)
        try make("mid", 200)
        try make("new", 100)
        try make("half", 50, jpeg: false)
        XCTAssertNil(cache.entry(key: "half", name: "X-HDR"))
        XCTAssertNotNil(cache.entry(key: "old", name: "X-HDR")) // now the most recently used
        cache.prune(keep: 2)
        XCTAssertNotNil(cache.entry(key: "old", name: "X-HDR"))
        XCTAssertNil(cache.entry(key: "mid", name: "X-HDR"))
        XCTAssertNil(cache.entry(key: "new", name: "X-HDR"))
    }
}
