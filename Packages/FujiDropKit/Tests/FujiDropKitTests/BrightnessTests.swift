import XCTest
@testable import FujiDropKit

final class BrightnessTests: XCTestCase {
    /// A flat image whose linear light is `linear` (0…1), encoded as sRGB.
    private func flat(linear: Float) -> GrayImage {
        let c = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        let v = UInt8((c * 255).rounded())
        return GrayImage(width: 16, height: 16, pixels: [UInt8](repeating: v, count: 256))
    }

    func testOneStopIsOne() {
        let stops = Brightness.stops(toMatch: flat(linear: 0.2), from: flat(linear: 0.1))
        XCTAssertEqual(stops, 1, accuracy: 0.05)
    }

    func testTwoStopsDarkerNeedsPlusTwo() {
        XCTAssertEqual(Brightness.stops(toMatch: flat(linear: 0.4), from: flat(linear: 0.1)), 2, accuracy: 0.05)
    }

    func testSameImageNeedsNothing() {
        XCTAssertEqual(Brightness.stops(toMatch: flat(linear: 0.3), from: flat(linear: 0.3)), 0, accuracy: 0.001)
    }

    func testBlackIsFlooredNotInfinite() {
        let black = GrayImage(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 16))
        XCTAssertTrue(Brightness.logAverage(black).isFinite)
    }
}
