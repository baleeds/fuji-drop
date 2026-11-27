import Foundation

/// False-colour suppression for X-Trans demosaicing, ported from `clean()` in
/// `tools/demosaic-compare/compare.py` (the study measured −47 % false colour for −3 % detail):
/// take log(rgb / luminance) ratios, median-filter them (5×5, two passes), and put the
/// original luminance back. Runs once on the merged image, white-balanced (so neutral is
/// ratio 0), in strips across the cores.
public enum ColorCleanup {
    static let radius = 2
    static let passes = 2
    static let strip = 64

    /// - Parameters:
    ///   - rgb: interleaved camera-native RGB.
    ///   - whiteBalance: multipliers applied before filtering and removed after.
    ///   - scale: applied to the output (e.g. 1 / peak).
    /// - Returns: cleaned camera-native RGB as half floats.
    public static func clean(_ rgb: [Float], width: Int, height: Int, whiteBalance wb: [Float],
                             scale: Float = 1) -> [Float16] {
        var out = [Float16](repeating: 0, count: rgb.count)
        let strips = (height + strip - 1) / strip
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let dst = Shared(dst)
                DispatchQueue.concurrentPerform(iterations: strips) { s in
                    cleanStrip(src, rows: s * strip..<min(height, (s + 1) * strip), width: width,
                               height: height, wb: wb, scale: scale, out: dst.value)
                }
            }
        }
        return out
    }

    @inline(__always) static func lum(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func cleanStrip(_ src: UnsafeBufferPointer<Float>, rows: Range<Int>, width w: Int, height h: Int,
                                   wb: [Float], scale: Float, out: UnsafeMutableBufferPointer<Float16>) {
        let margin = radius * passes
        let top = max(0, rows.lowerBound - margin), bottom = min(h, rows.upperBound + margin)
        let n = bottom - top
        // Log colour ratios of the strip plus its margin, planar per channel.
        var ratio = [Float](repeating: 0, count: n * w * 3)
        for y in top..<bottom {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let r = src[i] * wb[0], g = src[i + 1] * wb[1], b = src[i + 2] * wb[2]
                let l = max(lum(r, g, b), 1e-5)
                let o = (y - top) * w + x
                ratio[o] = log(max(r, 1e-5) / l)
                ratio[n * w + o] = log(max(g, 1e-5) / l)
                ratio[2 * n * w + o] = log(max(b, 1e-5) / l)
            }
        }
        // Each pass shrinks the valid rows by `radius` (unless at the image edge, where rows
        // are clamped like OpenCV's BORDER_REPLICATE).
        var filtered = ratio
        var validTop = top, validBottom = bottom
        for _ in 0..<passes {
            let nextTop = validTop == 0 ? 0 : validTop + radius
            let nextBottom = validBottom == h ? h : validBottom - radius
            ratio.withUnsafeBufferPointer { inp in
                filtered.withUnsafeMutableBufferPointer { outp in
                    withUnsafeTemporaryAllocation(of: Float.self, capacity: 25) { window in
                        for c in 0..<3 {
                            let plane = c * n * w
                            for y in nextTop..<nextBottom {
                                for x in 0..<w {
                                    var k = 0
                                    for dy in -radius...radius {
                                        let yy = min(max(y + dy, validTop), validBottom - 1) - top
                                        for dx in -radius...radius {
                                            let xx = min(max(x + dx, 0), w - 1)
                                            window[k] = inp[plane + yy * w + xx]
                                            k += 1
                                        }
                                    }
                                    outp[plane + (y - top) * w + x] = median(window.baseAddress!, 25)
                                }
                            }
                        }
                    }
                }
            }
            swap(&ratio, &filtered)
            validTop = nextTop
            validBottom = nextBottom
        }
        // Back to RGB with the original luminance, then without white balance.
        for y in rows {
            for x in 0..<w {
                let i = (y * w + x) * 3
                let r0 = src[i] * wb[0], g0 = src[i + 1] * wb[1], b0 = src[i + 2] * wb[2]
                let l = max(lum(r0, g0, b0), 1e-5)
                let o = (y - top) * w + x
                var r = exp(ratio[o]) * l, g = exp(ratio[n * w + o]) * l, b = exp(ratio[2 * n * w + o]) * l
                let fix = l / max(lum(r, g, b), 1e-5)
                r *= fix; g *= fix; b *= fix
                out[i] = Float16(r / wb[0] * scale)
                out[i + 1] = Float16(g / wb[1] * scale)
                out[i + 2] = Float16(b / wb[2] * scale)
            }
        }
    }

    /// Median by Wirth's selection; reorders `a`.
    @inline(__always) static func median(_ a: UnsafeMutablePointer<Float>, _ n: Int) -> Float {
        let k = n / 2
        var l = 0, m = n - 1
        while l < m {
            let x = a[k]
            var i = l, j = m
            repeat {
                while a[i] < x { i += 1 }
                while x < a[j] { j -= 1 }
                if i <= j {
                    let t = a[i]; a[i] = a[j]; a[j] = t
                    i += 1; j -= 1
                }
            } while i <= j
            if j < k { l = i }
            if k < i { m = j }
        }
        return a[k]
    }
}
