import XCTest
@testable import FujiDropKit

final class TimeSamplingTests: XCTestCase {
    private func at(_ minutes: Double) -> Date { Date(timeIntervalSinceReferenceDate: minutes * 60) }

    func testSpreadsAcrossTheDayNotTheFirstFew() {
        // 9:00 burst of 10, one shot at 12:00, 17:00 burst of 10.
        var items: [(String, Date)] = (0..<10).map { ("m\($0)", at(540 + Double($0) * 0.1)) }
        items.append(("noon", at(720)))
        items += (0..<10).map { ("e\($0)", at(1020 + Double($0) * 0.1)) }

        let picked = TimeSampling.spread(items, count: 3, date: { $0.1 }).map(\.0)
        XCTAssertEqual(picked, ["m0", "noon", "e9"])
    }

    func testFourPicksStayInOrderAndDistinct() {
        let items = (0..<20).map { ("s\($0)", at(Double($0))) }
        let picked = TimeSampling.spread(items, count: 4, date: { $0.1 }).map(\.0)
        XCTAssertEqual(picked, ["s0", "s6", "s13", "s19"])
    }

    func testFewerItemsThanCountReturnsAll() {
        let items = [("a", at(0)), ("b", at(5))]
        XCTAssertEqual(TimeSampling.spread(items, count: 4, date: { $0.1 }).map(\.0), ["a", "b"])
    }

    func testUndatedFallsBackToPosition() {
        let items = (0..<9).map { "s\($0)" }
        XCTAssertEqual(TimeSampling.spread(items, count: 3, date: { _ in nil }), ["s0", "s4", "s8"])
    }

    func testEdgeCounts() {
        let items = (0..<5).map { ("s\($0)", at(Double($0))) }
        XCTAssertEqual(TimeSampling.spread(items, count: 0, date: { $0.1 }).count, 0)
        XCTAssertEqual(TimeSampling.spread(items, count: 1, date: { $0.1 }).map(\.0), ["s0"])
    }
}
