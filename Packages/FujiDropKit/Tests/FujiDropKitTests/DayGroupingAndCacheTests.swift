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
    func testStoreAndLookup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PreviewCache(directory: dir)

        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 100))
        let url = try cache.store(Data([1, 2, 3]), name: "DSCF0001", size: 100)
        XCTAssertEqual(cache.cachedURL(name: "DSCF0001", size: 100), url)
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertNil(cache.cachedURL(name: "DSCF0001", size: 101), "different size is a different file")
    }
}
