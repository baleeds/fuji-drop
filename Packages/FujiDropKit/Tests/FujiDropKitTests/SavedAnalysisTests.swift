@testable import FujiDropKit
import CoreGraphics
import XCTest

final class SavedAnalysisTests: XCTestCase {
    private let score = ShotScore(sharpness: 48, faceQuality: 0.63, aesthetics: 0.37,
                                  faces: [FaceBox(rect: CGRect(x: 0.4, y: 0.2, width: 0.1, height: 0.12), eyeOpenness: 0.31),
                                          FaceBox(rect: CGRect(x: 0.7, y: 0.3, width: 0.05, height: 0.06))])

    func testScoreRoundTrips() throws {
        let data = try XCTUnwrap(SavedAnalysis.encode(score, system: "iOS A"))
        XCTAssertEqual(SavedAnalysis.score(from: data, system: "iOS A"), score)
    }

    func testScoreFromAnotherSystemIsIgnored() throws {
        let data = try XCTUnwrap(SavedAnalysis.encode(score, system: "iOS A"))
        XCTAssertNil(SavedAnalysis.score(from: data, system: "iOS B"))
    }

    func testOtherVersionIsIgnored() throws {
        let old = SavedAnalysis.ScoreFile(version: SavedAnalysis.scoreVersion - 1, system: "iOS A", score: score)
        let data = try PropertyListEncoder().encode(old)
        XCTAssertNil(SavedAnalysis.score(from: data, system: "iOS A"))
        XCTAssertNil(SavedAnalysis.score(from: Data("junk".utf8), system: "iOS A"))
    }

    func testFeaturePrintRoundTrips() throws {
        // A small synthetic image: Vision computes prints on the Mac too.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let image = try XCTUnwrap(ctx.makeImage())
        let print = try FeaturePrinter.featurePrint(of: image)

        let data = try XCTUnwrap(SavedAnalysis.encode(print, system: "iOS A"))
        let restored = try XCTUnwrap(SavedAnalysis.print(from: data, system: "iOS A"))
        XCTAssertEqual(restored.revision, print.revision)
        XCTAssertEqual(try XCTUnwrap(restored.distance(to: print)), 0, accuracy: 1e-6)
        XCTAssertNil(SavedAnalysis.print(from: data, system: "iOS B"))
    }
}
