import XCTest
@testable import FujiDropKit

final class ShotPairingTests: XCTestCase {
    func testPairsByBasenameCaseInsensitive() {
        let files = ["DSCF0002.RAF", "DSCF0001.JPG", "dscf0001.raf", "DSCF0002.JPG", "DSCF0003.JPG", "DSCF0004.MOV"]
        let shots = ShotPairing.pair(files) { $0 }
        XCTAssertEqual(shots.map(\.basename), ["DSCF0001", "DSCF0002", "DSCF0003", "DSCF0004"])
        XCTAssertEqual(shots[0].jpeg, "DSCF0001.JPG")
        XCTAssertEqual(shots[0].raw, "dscf0001.raf")
        XCTAssertTrue(shots[1].isComplete)
        XCTAssertFalse(shots[2].isComplete)
        XCTAssertEqual(shots[3].others, ["DSCF0004.MOV"])
    }
}
