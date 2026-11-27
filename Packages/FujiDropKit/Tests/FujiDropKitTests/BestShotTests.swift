import CoreGraphics
import XCTest
@testable import FujiDropKit

final class BestShotTests: XCTestCase {
    // MARK: Sharpness

    /// A checkerboard of `cell`-pixel squares, optionally box-blurred.
    private func checkerboard(size: Int = 256, cell: Int = 8, blur: Int = 0) -> GrayImage {
        var px = (0..<size * size).map { i -> UInt8 in
            ((i % size / cell + i / size / cell) % 2 == 0) ? 40 : 215
        }
        if blur > 0 {
            var out = px
            for y in 0..<size {
                for x in 0..<size {
                    var sum = 0, n = 0
                    for dy in -blur...blur {
                        for dx in -blur...blur {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, xx < size, yy >= 0, yy < size else { continue }
                            sum += Int(px[yy * size + xx]); n += 1
                        }
                    }
                    out[y * size + x] = UInt8(sum / n)
                }
            }
            px = out
        }
        return GrayImage(width: size, height: size, pixels: px)
    }

    func testSharperImageScoresHigher() {
        let sharp = Sharpness.score(checkerboard())
        let soft = Sharpness.score(checkerboard(blur: 1))
        let softer = Sharpness.score(checkerboard(blur: 3))
        XCTAssertGreaterThan(sharp, soft)
        XCTAssertGreaterThan(soft, softer)
    }

    func testFlatImageScoresZero() {
        let flat = GrayImage(width: 128, height: 128, pixels: [UInt8](repeating: 128, count: 128 * 128))
        XCTAssertEqual(Sharpness.score(flat), 0)
    }

    func testRegionLimitsMeasurement() {
        // Left half detailed, right half flat.
        let size = 256
        let board = checkerboard(size: size)
        var px = board.pixels
        for y in 0..<size { for x in size / 2..<size { px[y * size + x] = 128 } }
        let image = GrayImage(width: size, height: size, pixels: px)
        let left = Sharpness.score(image, region: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let right = Sharpness.score(image, region: CGRect(x: 0.55, y: 0, width: 0.45, height: 1))
        XCTAssertGreaterThan(left, 0)
        XCTAssertEqual(right, 0)
    }

    func testTinyRegionStillMeasures() {
        let score = Sharpness.score(checkerboard(), region: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1))
        XCTAssertGreaterThan(score, 0)
    }

    func testGrayImageFromCGImageKeepsTopRowAtTop() throws {
        // 2×2 RGBA: top row white, bottom row black.
        let rgba: [UInt8] = [255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255, 0, 0, 0, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let cg = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let gray = try XCTUnwrap(GrayImage(cg))
        XCTAssertGreaterThan(gray.pixels[0], 200)
        XCTAssertLessThan(gray.pixels[2], 50)
    }

    // MARK: Ranking

    func testSharpestWinsWithoutOtherSignals() {
        let scores = [ShotScore(sharpness: 100), ShotScore(sharpness: 400), ShotScore(sharpness: 50)]
        XCTAssertEqual(BestShot.bestIndex(scores), 1)
        XCTAssertEqual(BestShot.rank(scores)[1].total, 1, accuracy: 1e-6)
    }

    func testFaceQualityCanOutweighSlightlySofterFocus() {
        // Frame 0 a little sharper but eyes closed; frame 1 nearly as sharp with a good face.
        let scores = [ShotScore(sharpness: 100, faceQuality: 0.1, aesthetics: 0),
                      ShotScore(sharpness: 90, faceQuality: 0.8, aesthetics: 0)]
        XCTAssertEqual(BestShot.bestIndex(scores), 1)
    }

    func testMissingFaceCountsAsZeroWhenOthersHaveFaces() {
        let ranked = BestShot.rank([ShotScore(sharpness: 100), ShotScore(sharpness: 100, faceQuality: 0.5)])
        XCTAssertEqual(ranked[0].face, 0)
        XCTAssertLessThan(ranked[0].total, ranked[1].total)
    }

    func testNoFacesMeansNoFaceTerm() {
        let ranked = BestShot.rank([ShotScore(sharpness: 100, aesthetics: 0.2)])
        XCTAssertNil(ranked[0].face)
        XCTAssertEqual(ranked[0].aesthetics ?? -1, 0.6, accuracy: 1e-6)
    }

    func testSoftFocusIsRelative() {
        let ranked = BestShot.rank([ShotScore(sharpness: 100), ShotScore(sharpness: 30)])
        XCTAssertEqual(ranked[0].flaws, [])
        XCTAssertEqual(ranked[1].flaws, [.softFocus])
        XCTAssertEqual(BestShot.rank([ShotScore(sharpness: 1)])[0].flaws, [], "a lone frame isn't soft")
    }

    func testClosedEyesFlaggedAndPenalised() {
        // Equally sharp; closed eyes should lose even with a slightly better face score.
        let scores = [ShotScore(sharpness: 100, faceQuality: 0.6, eyeOpenness: 0.08),
                      ShotScore(sharpness: 100, faceQuality: 0.55, eyeOpenness: 0.32)]
        let ranked = BestShot.rank(scores)
        XCTAssertEqual(ranked[0].flaws, [.eyesClosed])
        XCTAssertEqual(ranked[1].flaws, [])
        XCTAssertEqual(BestShot.bestIndex(scores), 1)
    }

    func testUnclearFaceOnlyWhenAnotherFrameIsClear() {
        XCTAssertEqual(BestShot.rank([ShotScore(sharpness: 1, faceQuality: 0.2),
                                      ShotScore(sharpness: 1, faceQuality: 0.7)])[0].flaws, [.faceUnclear])
        XCTAssertEqual(BestShot.rank([ShotScore(sharpness: 1, faceQuality: 0.2),
                                      ShotScore(sharpness: 1, faceQuality: 0.25)])[0].flaws, [])
    }

    func testTiesGoToEarlierFrame() {
        XCTAssertEqual(BestShot.bestIndex([ShotScore(sharpness: 10), ShotScore(sharpness: 10)]), 0)
    }

    func testEmpty() {
        XCTAssertNil(BestShot.bestIndex([ShotScore]()))
        XCTAssertEqual(BestShot.rank([]), [])
    }
}
