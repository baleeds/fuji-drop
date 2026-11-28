@testable import FujiDropKit
import XCTest

final class FujiCameraTests: XCTestCase {
    func testModelNameDropsMaker() {
        XCTAssertEqual(FujiCamera(name: "X-T1").model, "X-T1")
        XCTAssertEqual(FujiCamera(name: "FUJIFILM X-T5").model, "X-T5")
        XCTAssertEqual(FujiCamera(name: "Fujifilm X100V").model, "X100V")
        XCTAssertEqual(FujiCamera(name: "FUJIFILM GFX 50S II").model, "GFX 50S II")
        XCTAssertEqual(FujiCamera(name: nil).model, "")
    }

    func testXTransBodies() {
        for name in ["X-T1", "X-T2", "X-Pro1", "X-E4", "X-H2S", "X-S10", "X100V", "X100F", "X-M1", "X-M5", "X30"] {
            let camera = FujiCamera(name: name)
            XCTAssertEqual(camera.sensor, .xTrans, name)
            XCTAssertTrue(camera.supportsXTransProcessing, name)
        }
    }

    func testBayerBodies() {
        for name in ["X-A5", "X-A10", "X-T100", "X-T200", "X100", "XF10", "GFX 100S", "GFX100 II"] {
            let camera = FujiCamera(name: name)
            XCTAssertEqual(camera.sensor, .bayer, name)
            XCTAssertFalse(camera.supportsXTransProcessing, name)
        }
    }

    func testUnknownStillOffersXTransProcessing() {
        let camera = FujiCamera(name: "")
        XCTAssertEqual(camera.sensor, .unknown)
        XCTAssertTrue(camera.supportsXTransProcessing)
    }

    func testHighResolution() {
        XCTAssertTrue(FujiCamera(name: "X-T5").isHighResolution)
        XCTAssertTrue(FujiCamera(name: "FUJIFILM X-H2").isHighResolution)
        XCTAssertFalse(FujiCamera(name: "X-H2S").isHighResolution)
        XCTAssertFalse(FujiCamera(name: "X-T1").isHighResolution)
    }
}
