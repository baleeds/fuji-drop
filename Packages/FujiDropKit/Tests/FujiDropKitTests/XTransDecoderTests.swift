import FujiDropKit
import XCTest

/// Decodes a real X-T1 RAF. Set `FUJIDROP_TEST_RAF` to its path; skipped otherwise (CI
/// downloads a raw.pixls.us sample).
final class XTransDecoderTests: XCTestCase {
    func testDecodesRAF() throws {
        guard let path = ProcessInfo.processInfo.environment["FUJIDROP_TEST_RAF"] else {
            throw XCTSkip("Set FUJIDROP_TEST_RAF to an X-T1 RAF to run this test.")
        }
        let started = Date()
        let image = try XTransDecoder.decode(URL(fileURLWithPath: path))
        print(String(format: "LibRaw %@ decoded %dx%d in %.2f s", XTransDecoder.libRawVersion,
                     image.width, image.height, Date().timeIntervalSince(started)))
        XCTAssertEqual(image.make.uppercased(), "FUJIFILM")
        XCTAssertGreaterThan(image.width * image.height, 15_000_000)
        XCTAssertEqual(image.pixels.count, image.width * image.height * 3)
        XCTAssertEqual(image.wb.min() ?? 0, 1, accuracy: 1e-4)
        XCTAssertFalse(image.camXYZ.allSatisfy { $0 == 0 })
        XCTAssertNotNil(image.exposure)
        // Linear data: plenty of distinct values, not all clipped or black.
        let mean = image.pixels.lazy.map(Double.init).reduce(0, +) / Double(image.pixels.count)
        XCTAssertGreaterThan(mean, 100)
        XCTAssertLessThan(mean, 60_000)
        // Upright: portrait frames (EXIF orientation 5–8) come out taller than wide.
        let orientation = image.properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        XCTAssertEqual(image.height > image.width, orientation >= 5)
    }

    /// Decoding in parallel bands gives the same pixels as one whole-frame decode, except along
    /// the seams of LibRaw's own 512 px Markesteijn tiles, which land in different places
    /// (measured: 0.16 % of values on ~95 rows, all at tile seams, none at band seams).
    func testBandsMatchWholeFrame() throws {
        guard let path = ProcessInfo.processInfo.environment["FUJIDROP_TEST_RAF"] else {
            throw XCTSkip("Set FUJIDROP_TEST_RAF to an X-T1 RAF to run this test.")
        }
        let url = URL(fileURLWithPath: path)
        let banded = try XTransDecoder.decode(url, bands: 4)
        let whole = try XTransDecoder.decode(url, bands: 1)
        XCTAssertEqual(banded.width, whole.width)
        XCTAssertEqual(banded.height, whole.height)
        XCTAssertEqual(banded.wb, whole.wb)
        var differing = 0, maxDiff = 0
        for i in whole.pixels.indices where banded.pixels[i] != whole.pixels[i] {
            differing += 1
            maxDiff = max(maxDiff, abs(Int(banded.pixels[i]) - Int(whole.pixels[i])))
        }
        print("Bands vs whole: \(differing) of \(whole.pixels.count) values differ, max \(maxDiff)")
        XCTAssertLessThan(Double(differing) / Double(whole.pixels.count), 0.005)
    }
}
