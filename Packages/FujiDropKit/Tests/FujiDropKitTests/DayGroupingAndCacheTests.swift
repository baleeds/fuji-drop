import XCTest
@testable import FujiDropKit

final class DayGroupingTests: XCTestCase {
    func testGroupsByDayNewestFirstUndatedLast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func d(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let items: [(String, Date?)] = [
            ("a", d(25, 9)), ("b", d(26, 23)), ("c", nil), ("d", d(25, 18)), ("e", d(26, 1)),
        ]
        let groups = DayGrouping.group(items, date: { $0.1 }, calendar: cal)
        XCTAssertEqual(groups.map { $0.items.map(\.0) }, [["b", "e"], ["a", "d"], ["c"]])
        XCTAssertEqual(groups.map(\.day), [d(26, 0), d(25, 0), nil])
    }
}

final class PreviewCacheTests: XCTestCase {
    private var dir: URL!
    private var cache: PreviewCache!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = PreviewCache(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Stores a file of `bytes` bytes last used `daysAgo` days before `now`.
    @discardableResult
    private func put(_ name: String, bytes: Int, daysAgo: Double, now: Date) throws -> URL {
        let url = try cache.store(Data(count: bytes), name: name, size: Int64(bytes))
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
        return url
    }

    func testStoreAndLookup() throws {
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 100))
        let url = try cache.store(Data([1, 2, 3]), name: "DSCF0001", size: 100)
        XCTAssertEqual(cache.cachedURL(name: "DSCF0001", size: 100), url)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 101), "different size is a different file")
    }

    func testPruneRemovesStaleThenLeastRecentlyUsed() throws {
        let now = Date()
        try put("old", bytes: 100, daysAgo: 40, now: now)
        try put("a", bytes: 100, daysAgo: 3, now: now)
        try put("b", bytes: 100, daysAgo: 2, now: now)
        try put("c", bytes: 100, daysAgo: 1, now: now)

        let result = cache.prune(maxBytes: 250, maxAge: 30 * 86400, now: now)

        XCTAssertEqual(result.removed, .init(files: 2, bytes: 200)) // "old" by age, "a" by size
        XCTAssertEqual(result.remaining, .init(files: 2, bytes: 200))
        XCTAssertNil(cache.cachedURL(name: "old", size: 100))
        XCTAssertNil(cache.cachedURL(name: "a", size: 100))
        XCTAssertNotNil(cache.cachedURL(name: "b", size: 100))
        XCTAssertNotNil(cache.cachedURL(name: "c", size: 100))
    }

    func testSidecarsAreTrimmedWithTheirPreviewAndNotCounted() throws {
        let now = Date()
        try put("a", bytes: 100, daysAgo: 3, now: now)
        try put("b", bytes: 100, daysAgo: 1, now: now)
        cache.writeSidecar(Data(count: 10), .score, name: "a", size: 100)
        cache.writeSidecar(Data(count: 10), .print, name: "a", size: 100)
        cache.writeSidecar(Data(count: 10), .score, name: "b", size: 100)
        XCTAssertEqual(cache.readSidecar(.score, name: "a", size: 100), Data(count: 10))
        XCTAssertEqual(cache.usage(), .init(files: 2, bytes: 230))

        // Over the cap: "a" is the oldest preview, and its sidecars go with it (even though
        // reading one just made it recent).
        let result = cache.prune(maxBytes: 150, maxAge: 30 * 86400, now: now)

        XCTAssertEqual(result.removed, .init(files: 1, bytes: 120))
        XCTAssertEqual(result.remaining, .init(files: 1, bytes: 110))
        XCTAssertNil(cache.readSidecar(.score, name: "a", size: 100))
        XCTAssertNil(cache.readSidecar(.print, name: "a", size: 100))
        XCTAssertNotNil(cache.readSidecar(.score, name: "b", size: 100))
    }

    func testRemoveDropsSidecars() throws {
        try cache.store(Data(count: 5), name: "a", size: 5)
        cache.writeSidecar(Data(count: 1), .score, name: "a", size: 5)
        cache.remove(name: "a", size: 5)
        XCTAssertNil(cache.cachedURL(name: "a", size: 5))
        XCTAssertNil(cache.readSidecar(.score, name: "a", size: 5))
    }

    func testCacheHitProtectsEntryFromEviction() throws {
        let now = Date()
        try put("a", bytes: 100, daysAgo: 3, now: now)
        try put("b", bytes: 100, daysAgo: 2, now: now)
        _ = cache.cachedURL(name: "a", size: 100, now: now) // "a" is now the most recent

        cache.prune(maxBytes: 150, maxAge: 30 * 86400, now: now)

        XCTAssertNotNil(cache.cachedURL(name: "a", size: 100))
        XCTAssertNil(cache.cachedURL(name: "b", size: 100))
    }

    func testPerCameraFoldersAreSeparateButPrunedTogether() throws {
        let a = cache.scoped(to: "X-T1 123/45"), b = cache.scoped(to: "X-T2")
        let urlA = try a.store(Data(count: 100), name: "DSCF0001", size: 100)
        try b.store(Data(count: 50), name: "DSCF0001", size: 100)
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertFalse(urlA.path.contains("123/45"), "camera id is made safe for a folder name")
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 100), "the parent doesn't see camera files")
        XCTAssertEqual(cache.usage(), .init(files: 2, bytes: 150))
        XCTAssertEqual(cache.clear(), .init(files: 2, bytes: 150))
        XCTAssertNil(a.cachedURL(name: "DSCF0001", size: 100))
    }

    func testRemoveDropsOneEntry() throws {
        try cache.store(Data([1]), name: "DSCF0001", size: 1)
        cache.remove(name: "DSCF0001", size: 1)
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 1))
    }

    func testClearAndUsage() throws {
        let now = Date()
        try put("a", bytes: 100, daysAgo: 0, now: now)
        try put("b", bytes: 50, daysAgo: 0, now: now)
        XCTAssertEqual(cache.usage(), .init(files: 2, bytes: 150))
        XCTAssertEqual(cache.clear(), .init(files: 2, bytes: 150))
        XCTAssertEqual(cache.usage(), .init(files: 0, bytes: 0))
    }
}
