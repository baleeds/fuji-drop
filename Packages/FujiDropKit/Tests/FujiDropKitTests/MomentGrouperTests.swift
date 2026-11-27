import XCTest
@testable import FujiDropKit

final class MomentGrouperTests: XCTestCase {
    struct Shot { var t: TimeInterval; var look: Float }

    private func group(_ shots: [Shot], visual: Bool = true) -> [[TimeInterval]] {
        let grouper = MomentGrouper() // split 0.6 within 3 s; join ≤ 0.3 within 180 s
        let distance: ((Shot, Shot) -> Float?)? = visual ? { abs($0.look - $1.look) } : nil
        return grouper
            .group(shots, date: { Date(timeIntervalSince1970: $0.t) }, distance: distance)
            .map { $0.map(\.t) }
    }

    func testBurstStaysTogetherTimeOnly() {
        let shots = [Shot(t: 0, look: 0), Shot(t: 1, look: 0), Shot(t: 2.5, look: 0), Shot(t: 30, look: 0)]
        XCTAssertEqual(group(shots, visual: false), [[0, 1, 2.5], [30]])
    }

    func testSortsInputByDate() {
        let shots = [Shot(t: 2, look: 0), Shot(t: 0, look: 0), Shot(t: 1, look: 0)]
        XCTAssertEqual(group(shots), [[0, 1, 2]])
    }

    func testSameSecondKeepsInputOrder() {
        // Burst frames often share a timestamp; the caller's order (by filename) must survive.
        let grouper = MomentGrouper()
        let names = ["DSCF0003", "DSCF0004", "DSCF0005"]
        let result = grouper.group(names, date: { _ in Date(timeIntervalSince1970: 0) })
        XCTAssertEqual(result, [names])
    }

    func testQuickSwingToNewSubjectSplits() {
        let shots = [Shot(t: 0, look: 0), Shot(t: 1, look: 1.0)]
        XCTAssertEqual(group(shots), [[0], [1]])
    }

    func testSameSceneMinutesLaterJoinsOnlyIfVeryClose() {
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 60, look: 0.2)]), [[0, 60]])
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 60, look: 0.5)]), [[0], [60]])
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 600, look: 0)]), [[0], [600]])
    }

    func testEmpty() {
        XCTAssertEqual(group([]), [])
    }
}
