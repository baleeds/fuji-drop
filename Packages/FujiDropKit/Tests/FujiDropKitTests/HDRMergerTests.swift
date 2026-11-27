import FujiDropKit
import XCTest

/// Synthetic brackets: one linear scene, captured at several exposures with clipping, should
/// merge back into the scene.
final class HDRMergerTests: XCTestCase {
    let w = 192, h = 128
    let wb: [Float] = [2.0, 1.0, 1.5]

    /// Camera-native scene: a smooth horizontal ramp over 9 stops with a little colour, so
    /// every clip boundary of every frame crosses it.
    func scene(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let t = Float(x) / Float(w - 1)
        let v = 0.004 * pow(2, 9 * t)  // 0.004 … 2.0 (twice the reference's clip)
        let tint = 1 + 0.1 * sin(Float(y) / 9)
        return SIMD3(v * tint, v, v / tint)
    }

    /// A frame `stops` brighter than the reference: what the sensor records, white-balanced
    /// and clipped as LibRaw delivers it.
    func frame(stops: Float, shift: (Int, Int) = (0, 0)) -> XTransImage {
        var px = [UInt16](repeating: 0, count: w * h * 3)
        let gain = pow(2, stops)
        for y in 0..<h {
            for x in 0..<w {
                // Content shifted right/down by `shift`.
                let s = scene(min(max(x - shift.0, 0), w - 1), min(max(y - shift.1, 0), h - 1)) * gain
                for c in 0..<3 {
                    px[(y * w + x) * 3 + c] = UInt16(min(max(s[c] * wb[c] * 65535, 0), 65535).rounded())
                }
            }
        }
        let e = Exposure(time: Double(gain) / 125, fNumber: 8, iso: 200, bias: Double(stops))
        return XTransImage(width: w, height: h, pixels: px, wb: wb, camXYZ: [Float](repeating: 0.3, count: 9),
                           make: "FUJIFILM", model: "X-T1", exposure: e)
    }

    func options() -> HDRMerger.Options {
        var o = HDRMerger.Options()
        o.align = false
        o.cleanup = false
        return o
    }

    /// Worst relative error against the scene where the darkest frame isn't clipped.
    func check(_ m: MergedImage, darkest: Float, file: StaticString = #filePath, line: UInt = #line) {
        var worst: Float = 0
        for y in 0..<h {
            for x in 0..<w {
                let s = scene(x, y)
                guard (s * pow(2, darkest) * SIMD3(wb[0], wb[1], wb[2])).max() < 0.9 else { continue }
                for c in 0..<3 {
                    let v = Float(m.pixels[(y * w + x) * 3 + c]) * m.scale
                    worst = max(worst, abs(v - s[c]) / s[c])
                }
            }
        }
        XCTAssertLessThan(worst, 0.01, file: file, line: line)
    }

    func testOneStopBracketReconstructsTheScene() throws {
        let m = try HDRMerger.merge([frame(stops: 0), frame(stops: 1), frame(stops: -1)], reference: 0, options: options())
        check(m, darkest: -1)
        XCTAssertEqual(m.crop.width, w)
    }

    func testTwoStopBracketReconstructsTheScene() throws {
        let m = try HDRMerger.merge([frame(stops: -2), frame(stops: 0), frame(stops: 2)], reference: 1, options: options())
        check(m, darkest: -2)
    }

    /// No seams: along the ramp, neighbouring pixels never jump more than the ramp itself
    /// does (each pixel is 9/191 stop brighter than the last).
    func testNoSeamsAtClipBoundaries() throws {
        let m = try HDRMerger.merge([frame(stops: -2), frame(stops: 0), frame(stops: 2)], reference: 1, options: options())
        let step = pow(2, Float(9) / Float(w - 1))
        for y in stride(from: 0, to: h, by: 7) {
            for x in 1..<w {
                let a = Float(m.pixels[(y * w + x - 1) * 3 + 1]), b = Float(m.pixels[(y * w + x) * 3 + 1])
                guard a > 0 else { continue }
                XCTAssertEqual(b / a, step, accuracy: 0.01, "x \(x) y \(y)")
            }
        }
    }

    /// A moving object in one frame is dropped there instead of leaving a ghost.
    func testGhostIsRemoved() throws {
        var bright = frame(stops: 1)
        // Something dark passes through the bright frame only.
        for y in 40..<80 {
            for x in 20..<60 { for c in 0..<3 { bright.pixels[(y * w + x) * 3 + c] = 50 } }
        }
        let m = try HDRMerger.merge([frame(stops: 0), bright, frame(stops: -1)], reference: 0, options: options())
        let x = 40, y = 60, s = scene(x, y)
        XCTAssertEqual(Float(m.pixels[(y * w + x) * 3 + 1]) * m.scale, s.y, accuracy: s.y * 0.02)
    }

    /// A ghost that only changes colour (a leg over ferns, same brightness) is caught too.
    func testColourOnlyGhostIsRemoved() throws {
        var bright = frame(stops: 1)
        for y in 40..<80 {
            for x in 20..<60 {
                let i = (y * w + x) * 3
                // Same luminance (R + 2G + B), colour moved from red to blue.
                let r = bright.pixels[i], b = bright.pixels[i + 2]
                bright.pixels[i] = UInt16(Double(r) * 0.4)
                bright.pixels[i + 2] = UInt16(min(65535, Double(b) + Double(r) * 0.6))
            }
        }
        let m = try HDRMerger.merge([frame(stops: 0), bright, frame(stops: -1)], reference: 0, options: options())
        let x = 40, y = 60, s = scene(x, y)
        XCTAssertEqual(Float(m.pixels[(y * w + x) * 3]) * m.scale, s.x, accuracy: s.x * 0.02)
    }

    /// The brightest merged value is 1 and `scale` says what that is.
    func testOutputIsNormalized() throws {
        let m = try HDRMerger.merge([frame(stops: 0), frame(stops: 1), frame(stops: -1)], reference: 0, options: options())
        let peak = m.pixels.map(Float.init).max() ?? 0
        XCTAssertEqual(peak, 1, accuracy: 0.001)
        XCTAssertGreaterThan(m.scale, 1)
    }

    func testRejectsMismatchedFrames() {
        let small = XTransImage(width: 4, height: 4, pixels: [UInt16](repeating: 0, count: 48), wb: wb,
                                camXYZ: [], exposure: Exposure(time: 0.01, fNumber: 8, iso: 200, bias: 0))
        XCTAssertThrowsError(try HDRMerger.merge([frame(stops: 0), small], reference: 0))
        XCTAssertThrowsError(try HDRMerger.merge([frame(stops: 0)], reference: 0))
    }

    // MARK: Colour cleanup

    func testCleanupKeepsFlatColourAndLuminance() {
        let n = 32
        let rgb = [Float]((0..<n * n).flatMap { _ in [0.2, 0.3, 0.1] as [Float] })
        let out = ColorCleanup.clean(rgb, width: n, height: n, whiteBalance: [1, 1, 1])
        for i in stride(from: 0, to: out.count, by: 3) {
            XCTAssertEqual(Float(out[i]), 0.2, accuracy: 0.002)
            XCTAssertEqual(Float(out[i + 1]), 0.3, accuracy: 0.002)
            XCTAssertEqual(Float(out[i + 2]), 0.1, accuracy: 0.002)
        }
    }

    func testCleanupRemovesIsolatedFalseColour() {
        let n = 32
        var rgb = [Float](repeating: 0.25, count: n * n * 3)
        let i = (16 * n + 16) * 3
        rgb[i] = 0.5; rgb[i + 1] = 0.1; rgb[i + 2] = 0.5 // a magenta speck in grey
        let out = ColorCleanup.clean(rgb, width: n, height: n, whiteBalance: [1, 1, 1])
        let r = Float(out[i]), g = Float(out[i + 1]), b = Float(out[i + 2])
        XCTAssertEqual(r, g, accuracy: 0.01)
        XCTAssertEqual(g, b, accuracy: 0.01)
        // Its luminance is kept.
        let lum = { (r: Float, g: Float, b: Float) in 0.2126 * r + 0.7152 * g + 0.0722 * b }
        XCTAssertEqual(lum(r, g, b), lum(0.5, 0.1, 0.5), accuracy: 0.002)
    }

    func testCleanupStripsMatchAcrossBoundaries() {
        // Taller than two strips (64 rows), with detail crossing their edges: an input that's
        // symmetric about row 75 stays symmetric, which it wouldn't if strips were stitched
        // wrongly (rows 64 and 128 aren't mirror images). Rows near the image edge are left
        // out: row 0 has no mirror row.
        let n = 40, hh = 150
        var rgb = [Float](repeating: 0, count: n * hh * 3)
        for y in 0..<hh {
            for x in 0..<n {
                let d = Float(abs(y - hh / 2)) + Float(x)
                rgb[(y * n + x) * 3] = 0.2 + 0.1 * sin(d)
                rgb[(y * n + x) * 3 + 1] = 0.2 + 0.1 * cos(d * 1.3)
                rgb[(y * n + x) * 3 + 2] = 0.2
            }
        }
        let out = ColorCleanup.clean(rgb, width: n, height: hh, whiteBalance: [1, 1, 1])
        for y in 5..<hh / 2 {
            for x in 0..<n {
                let a = (y * n + x) * 3, b = ((hh - y) * n + x) * 3
                XCTAssertEqual(Float(out[a]), Float(out[b]), accuracy: 1e-3, "row \(y)")
            }
        }
    }
}
