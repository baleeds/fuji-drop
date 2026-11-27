import CoreImage
@testable import FujiDropKit
import ImageIO
import XCTest

final class DNGWriterTests: XCTestCase {
    /// LibRaw's X-T1 ColorMatrix (XYZ → camera, ÷ 10000).
    let xt1: [Float] = [8458, -2451, -855, -4597, 12447, 2407, -1475, 2482, 6526].map { $0 / 10000 }
    let wb: [Float] = [1.9, 1.0, 1.6]

    /// Left half a neutral grey at `level` (camera-native, i.e. 1/wb tinted), right half a
    /// quarter of that.
    func image(level: Float, w: Int = 600, h: Int = 400) -> MergedImage {
        var px = [Float16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 { px[(y * w + x) * 3 + c] = Float16(level / wb[c] * (x < w / 2 ? 1 : 0.25)) }
            }
        }
        let exif: [String: Any] = [
            kCGImagePropertyExifExposureTime as String: 0.004,
            kCGImagePropertyExifFNumber as String: 8.0,
            kCGImagePropertyExifISOSpeedRatings as String: [200],
            kCGImagePropertyExifDateTimeOriginal as String: "2026:10:13 18:05:06",
        ]
        return MergedImage(width: w, height: h, pixels: px, crop: (10, 10, w - 20, h - 20), wb: wb, camXYZ: xt1,
                           make: "FUJIFILM", model: "X-T1",
                           properties: [kCGImagePropertyExifDictionary as String: exif], scale: 1, report: [])
    }

    func url(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name).dng")
    }

    /// Renders through Core Image's RAW pipeline (what Photos uses) and returns the mean
    /// sRGB values of the left and right halves.
    func render(_ dng: URL, exposure: Float = 0) throws -> (left: SIMD3<Float>, right: SIMD3<Float>) {
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: dng))
        filter.exposure = exposure
        let out = try XCTUnwrap(filter.outputImage)
        let extent = out.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        XCTAssertGreaterThan(w, 100, "fell back to the preview: the main image didn't decode")
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        CIContext().render(out, toBitmap: &rgba, rowBytes: w * 4, bounds: extent, format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        func mean(_ xs: Range<Int>) -> SIMD3<Float> {
            var s = SIMD3<Float>(repeating: 0), n: Float = 0
            for y in h / 4..<3 * h / 4 {
                for x in xs {
                    let i = (y * w + x) * 4
                    s += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
                    n += 1
                }
            }
            return s / n
        }
        return (mean(w / 8..<3 * w / 8), mean(5 * w / 8..<7 * w / 8))
    }

    func testCoreImageReadsItAsANeutralRAW() throws {
        let dng = url("neutral")
        try DNGWriter.write(image(level: 0.18), to: dng, baselineExposure: 0, preview: nil)
        let (left, right) = try render(dng)
        // Neutral stays neutral (ColorMatrix1 + AsShotNeutral are consistent).
        XCTAssertEqual(left.x, left.y, accuracy: 6)
        XCTAssertEqual(left.z, left.y, accuracy: 6)
        // Sensible brightness, and the darker half is darker.
        XCTAssertGreaterThan(left.y, 80)
        XCTAssertLessThan(left.y, 250)
        XCTAssertLessThan(right.y, left.y - 30)
        // Default crop and EXIF come through.
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: dng))
        XCTAssertEqual(filter.nativeSize, CGSize(width: 580, height: 380))
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(dng as CFURL, nil)!, 0, nil) as? [String: Any]
        let exif = props?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual((exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? 0, 0.004, accuracy: 1e-6)
    }

    func testBaselineExposureBrightens() throws {
        let plain = url("plain"), lifted = url("lifted")
        try DNGWriter.write(image(level: 0.05), to: plain, baselineExposure: 0, preview: nil)
        try DNGWriter.write(image(level: 0.05), to: lifted, baselineExposure: 1, preview: nil)
        XCTAssertEqual(CIRAWFilter(imageURL: lifted)?.baselineExposure ?? 0, 1, accuracy: 0.01)
        XCTAssertGreaterThan(try render(lifted).left.y, try render(plain).left.y + 20)
    }

    func testPreviewIsStoredInIFD0() throws {
        let dng = url("preview")
        let preview = DNGWriter.Preview(width: 30, height: 20, rgb: [UInt8](repeating: 128, count: 30 * 20 * 3))
        try DNGWriter.write(image(level: 0.18), to: dng, baselineExposure: 0, preview: preview)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(dng as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertGreaterThan(try render(dng).left.y, 80) // the main image still decodes
    }

    /// TIFF needs a zlib stream (header + Adler-32), not raw DEFLATE.
    func testZlibStreamHeader() throws {
        let data = try XCTUnwrap(DNGWriter.zlib([UInt8](repeating: 7, count: 1000)))
        XCTAssertEqual(Array(data.prefix(2)), [0x78, 0x9C])
        // Adler-32 of 1000 × 7: a = 1 + 7000, b = Σ a_i.
        let a = UInt32(1 + 7000) % 65521
        let b = UInt32((1...1000).reduce(0) { $0 + 1 + 7 * $1 }) % 65521
        let tail = Array(data.suffix(4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(tail, b << 16 | a)
    }
}
