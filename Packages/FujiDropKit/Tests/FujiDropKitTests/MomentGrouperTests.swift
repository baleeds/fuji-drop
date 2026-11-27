import XCTest
@testable import FujiDropKit

final class MomentGrouperTests: XCTestCase {
    struct Shot { var t: TimeInterval; var look: Float }

    private func group(_ shots: [Shot], visual: Bool = true) -> [[TimeInterval]] {
        let grouper = MomentGrouper()
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

    func testQuickSwingToNewSubjectSplits() {
        let shots = [Shot(t: 0, look: 0), Shot(t: 1, look: 50)]
        XCTAssertEqual(group(shots), [[0], [1]])
    }

    func testSameSceneMinutesLaterJoinsOnlyIfVeryClose() {
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 60, look: 5)]), [[0, 60]])
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 60, look: 15)]), [[0], [60]])
        XCTAssertEqual(group([Shot(t: 0, look: 0), Shot(t: 600, look: 0)]), [[0], [600]])
    }

    func testEmpty() {
        XCTAssertEqual(group([]), [])
    }
}
