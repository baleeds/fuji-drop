import FujiDropKit
import XCTest

final class BracketTests: XCTestCase {
    struct F {
        let t: Double       // seconds from start
        let e: Exposure?
        var scene = 0
    }

    /// A frame at second `t`: shutter `1/shutter`, ISO, compensation.
    func f(_ t: Double, _ shutter: Double, iso: Double = 400, bias: Double = 0, n: Double = 8, scene: Int = 0) -> F {
        F(t: t, e: Exposure(time: 1 / shutter, fNumber: n, iso: iso, bias: bias), scene: scene)
    }

    func find(_ frames: [F], _ finder: BracketFinder = BracketFinder()) -> [Range<Int>] {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return finder.find(frames, date: { start.addingTimeInterval($0.t) }, exposure: \.e,
                           distance: { $0.scene == $1.scene ? 0.1 : 1.0 })
    }

    func testExposureValue() {
        let e = Exposure(time: 1 / 125.0, fNumber: 8, iso: 100, bias: 0)
        XCTAssertEqual(e.ev, log2(64 * 125), accuracy: 1e-9)
        let brighter = Exposure(time: 1 / 125.0, fNumber: 8, iso: 200, bias: 0)
        XCTAssertEqual(brighter.stops(relativeTo: e), 1, accuracy: 1e-9)
    }

    /// X-T1 AE BKT ±1 around −1: frames at 0, +1, −1 relative (seen on the owner's card,
    /// DSCF2527–2529, with auto ISO doing the work).
    func testAEBracket() {
        let frames = [f(0, 100, iso: 1250, bias: -1), f(0.3, 100, iso: 2500, bias: 0), f(0.6, 105, iso: 800, bias: -2)]
        XCTAssertEqual(find(frames), [0..<3])
    }

    func testManualTwoStopBracketWithSlowDialTurns() {
        let frames = [f(0, 250, bias: -2), f(3, 60, bias: 0), f(7, 15, bias: 2)]
        XCTAssertEqual(find(frames), [0..<3])
    }

    /// A burst whose auto exposure drifted a stop between sub-bursts, compensation unchanged
    /// (DSCF2802–2816 on the owner's card). Not a bracket.
    func testBurstWithExposureDriftIsNotABracket() {
        let frames = [f(0, 2200), f(0.3, 2200), f(1, 1100), f(1.3, 1100), f(2, 1000), f(2.5, 1000)]
        XCTAssertEqual(find(frames), [])
        // Auto ISO jumping around with a fixed compensation (DSCF2669–2676).
        let iso = [f(0, 250, iso: 800, bias: -1), f(1, 480, iso: 800, bias: -1),
                   f(5, 100, iso: 800, bias: -1), f(7, 100, iso: 1600, bias: -1)]
        XCTAssertEqual(find(iso), [])
    }

    /// Two AE brackets back to back (DSCF2729–2734), plus normal frames around them.
    func testBackToBackBrackets() {
        let frames = [f(-20, 750, bias: -0.67),
                      f(0, 750, bias: -0.67), f(0.2, 350, bias: 0.33), f(0.4, 1500, bias: -1.67),
                      f(5, 750, bias: -0.67), f(5.2, 350, bias: 0.33), f(5.4, 1500, bias: -1.67),
                      f(6, 750, bias: -0.67)]
        XCTAssertEqual(find(frames), [1..<4, 4..<7])
    }

    func testBracketNeedsThreeFramesOneSceneAndShortGaps() {
        XCTAssertEqual(find([f(0, 250, bias: -1), f(0.3, 125, bias: 0)]), [])
        XCTAssertEqual(find([f(0, 250, bias: -1), f(0.3, 125, bias: 0), f(20, 60, bias: 1)]), [])
        XCTAssertEqual(find([f(0, 250, bias: -1), f(0.3, 125, bias: 0), f(0.6, 60, bias: 1, scene: 1)]), [])
        // A missing exposure breaks the run.
        XCTAssertEqual(find([f(0, 250, bias: -1), F(t: 0.3, e: nil), f(0.6, 60, bias: 1), f(0.9, 125, bias: 0)]), [])
    }

    /// A normal frame just before the bracket (same settings as the bracket's first frame) is
    /// left out.
    func testRepeatBeforeBracketIsDropped() {
        let frames = [f(0, 125, bias: 0), f(1, 125, bias: 0), f(1.3, 250, bias: -1), f(1.6, 60, bias: 1)]
        XCTAssertEqual(find(frames), [1..<4])
    }

    func testReferenceIsTheMiddleExposure() {
        let e = [Exposure(time: 1 / 125.0, fNumber: 8, iso: 400, bias: 0),
                 Exposure(time: 1 / 250.0, fNumber: 8, iso: 400, bias: -1),
                 Exposure(time: 1 / 60.0, fNumber: 8, iso: 400, bias: 1)]
        XCTAssertEqual(BracketFinder.referenceIndex(e), 0)
        XCTAssertEqual(BracketFinder.referenceIndex([e[1], e[2], e[0]]), 2)
    }

    /// Grouping cut the bracket in two (its frames are stops apart, so they can look
    /// different): the moments it spans are joined, others are left alone.
    func testBracketCutByGroupingIsRejoined() {
        let moments = [["a"], ["b", "c"], ["d"], ["e"], ["f"]]
        XCTAssertEqual(BracketFinder.keepTogether(moments, brackets: [["c", "d", "e"]]),
                       [["a"], ["b", "c", "d", "e"], ["f"]])
        XCTAssertEqual(BracketFinder.keepTogether(moments, brackets: [["b", "c"]]), moments)
        XCTAssertEqual(BracketFinder.keepTogether(moments, brackets: []), moments)
    }

    func testExposureFromProperties() {
        let props: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: 0.004,
                kCGImagePropertyExifFNumber as String: 5.6,
                kCGImagePropertyExifISOSpeedRatings as String: [200],
                kCGImagePropertyExifExposureBiasValue as String: -0.67,
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:13 18:05:06",
            ] as [String: Any],
        ]
        let e = Exposure(properties: props)
        XCTAssertEqual(e?.iso, 200)
        XCTAssertEqual(e?.bias, -0.67)
        XCTAssertNotNil(e?.date)
        XCTAssertNil(Exposure(properties: [:]))
    }
}
