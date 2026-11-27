import CoreGraphics
import simd
@testable import FujiDropKit
import XCTest

final class LinearRendererTests: XCTestCase {
    /// White-balanced white stays white, and grey stays grey.
    func testNeutralStaysNeutral() throws {
        let xt1: [Float] = [8458, -2451, -855, -4597, 12447, 2407, -1475, 2482, 6526].map { $0 / 10000 }
        let m = LinearRenderer.cameraToSRGB(xt1)
        let white = m * SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(white.x, 1, accuracy: 1e-4)
        XCTAssertEqual(white.y, 1, accuracy: 1e-4)
        XCTAssertEqual(white.z, 1, accuracy: 1e-4)
        let image = try XCTUnwrap(LinearRenderer.render(width: 8, height: 8, camXYZ: xt1, exposure: 0) { _ in
            SIMD3(repeating: 0.18)
        })
        let g = try XCTUnwrap(GrayImage(image))
        XCTAssertGreaterThan(g.pixels[0], 60)
        XCTAssertLessThan(g.pixels[0], 200)
    }

    func testCurvesAreMonotonicAndBounded() {
        for curve in LinearRenderer.Curve.allCases {
            var last: Float = -1
            for i in 0...200 {
                let v = Float(i) / 20 // 0…10
                let t = LinearRenderer.tone(SIMD3(repeating: v), curve).y
                XCTAssertGreaterThanOrEqual(t, last - 1e-5, "\(curve) at \(v)")
                last = t
            }
            XCTAssertLessThanOrEqual(LinearRenderer.tone(SIMD3(repeating: 4), curve).y, 4)
        }
    }

    /// Calibration: how close each curve's render gets to the camera's own JPEG. Set
    /// `FUJIDROP_TEST_RAFS` to RAF paths separated by commas.
    func testCurvesAgainstCameraJPEGs() throws {
        guard let list = ProcessInfo.processInfo.environment["FUJIDROP_TEST_RAFS"] else {
            throw XCTSkip("Set FUJIDROP_TEST_RAFS to comma-separated RAF paths to run this calibration.")
        }
        var totals: [LinearRenderer.Curve: Double] = [:]
        for path in list.split(separator: ",") {
            let url = URL(fileURLWithPath: String(path))
            let data = try Data(contentsOf: url)
            guard let header = RAFHeader(data.prefix(RAFHeader.readLength)),
                  let src = CGImageSourceCreateWithData(data.subdata(in: header.jpegOffset..<header.jpegOffset + header.jpegLength) as CFData, nil),
                  let jpeg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary)
            else { continue }
            let frame = try XTransDecoder.decode(url)
            let load: (Int) -> SIMD3<Float> = { i in
                SIMD3(Float(frame.pixels[i * 3]), Float(frame.pixels[i * 3 + 1]), Float(frame.pixels[i * 3 + 2])) / 65535
            }
            var line = url.lastPathComponent
            for curve in LinearRenderer.Curve.allCases {
                let ev = LinearRenderer.matchExposure(width: frame.width, height: frame.height, camXYZ: frame.camXYZ,
                                                      reference: jpeg, curve: curve, load: load)
                let factor = frame.width / 160
                guard let ours = LinearRenderer.render(width: frame.width, height: frame.height, camXYZ: frame.camXYZ,
                                                       exposure: ev, curve: curve, factor: factor, load: load) else { continue }
                let d = difference(ours, jpeg)
                totals[curve, default: 0] += d
                line += String(format: "  %@ %.1f (ev %+.2f)", curve.rawValue, d, ev)
            }
            print("CURVES", line)
        }
        print("CURVES total", totals.sorted { $0.value < $1.value }.map { "\($0.key.rawValue) \(String(format: "%.1f", $0.value))" })
    }

    /// Mean absolute difference per channel (0…255) after scaling both to 80 × 53.
    func difference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 80, h = 53
        func pixels(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0
        for i in 0..<w * h { for c in 0..<3 { sum += abs(Int(pa[i * 4 + c]) - Int(pb[i * 4 + c])) } }
        return Double(sum) / Double(w * h * 3)
    }
}
