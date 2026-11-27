import Foundation
import simd

/// False-colour suppression for X-Trans demosaicing, ported from `clean()` in
/// `tools/demosaic-compare/compare.py` (the study measured −47 % false colour for −3 % detail):
/// take log(rgb / luminance) ratios, median-filter them (5×5, two passes), and put the
/// original luminance back. Runs on white-balanced data (so neutral is ratio 0), in strips
/// across the cores: once on a merged image, or on a single frame for DNG saves.
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
        let gain = SIMD3(wb[0], wb[1], wb[2])
        rgb.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let dst = Shared(dst)
                run(width: width, height: height, load: { i in
                    SIMD3(src[i * 3], src[i * 3 + 1], src[i * 3 + 2]) * gain
                }, store: { i, v in
                    let n = v / gain * scale
                    dst.value[i * 3] = Float16(n.x); dst.value[i * 3 + 1] = Float16(n.y); dst.value[i * 3 + 2] = Float16(n.z)
                })
            }
        }
        return out
    }

    /// Cleans a decoded frame (LibRaw's white-balanced 16-bit output) and returns it
    /// camera-native (white balance divided out), still 16-bit: 65535 = sensor saturation.
    public static func clean(_ frame: XTransImage) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: frame.pixels.count)
        let gain = SIMD3(frame.wb[0], frame.wb[1], frame.wb[2])
        frame.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let dst = Shared(dst)
                run(width: frame.width, height: frame.height, load: { i in
                    SIMD3(Float(src[i * 3]), Float(src[i * 3 + 1]), Float(src[i * 3 + 2]))
                }, store: { i, v in
                    let n = (v / gain).rounded(.toNearestOrAwayFromZero)
                    let c = n.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 65535))
                    dst.value[i * 3] = UInt16(c.x); dst.value[i * 3 + 1] = UInt16(c.y); dst.value[i * 3 + 2] = UInt16(c.z)
                })
            }
        }
        return out
    }

    /// The filter over any source: `load(pixel)` gives white-balanced RGB, `store(pixel, rgb)`
    /// receives the cleaned white-balanced RGB. Strips run concurrently; each pixel is stored once.
    static func run(width: Int, height: Int, load: (Int) -> SIMD3<Float>, store: (Int, SIMD3<Float>) -> Void) {
        let strips = (height + strip - 1) / strip
        DispatchQueue.concurrentPerform(iterations: strips) { s in
            cleanStrip(rows: s * strip..<min(height, (s + 1) * strip), width: width, height: height,
                       load: load, store: store)
        }
    }

    @inline(__always) static func lum(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func cleanStrip(rows: Range<Int>, width w: Int, height h: Int,
                                   load: (Int) -> SIMD3<Float>, store: (Int, SIMD3<Float>) -> Void) {
        let margin = radius * passes
        let top = max(0, rows.lowerBound - margin), bottom = min(h, rows.upperBound + margin)
        let n = bottom - top
        // Log colour ratios of the strip plus its margin, planar per channel.
        var ratio = [Float](repeating: 0, count: n * w * 3)
        for y in top..<bottom {
            for x in 0..<w {
                let p = load(y * w + x)
                let r = p.x, g = p.y, b = p.z
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
                    withUnsafeTemporaryAllocation(of: SIMD8<Float>.self, capacity: 25) { window in
                        let window = window.baseAddress!
                        for c in 0..<3 {
                            let plane = c * n * w
                            for y in nextTop..<nextBottom {
                                var rows = [Int](repeating: 0, count: 5)
                                for dy in -radius...radius {
                                    rows[dy + radius] = plane + (min(max(y + dy, validTop), validBottom - 1) - top) * w
                                }
                                // 8 pixels at a time through the median network.
                                var x = 0
                                while x < w {
                                    var k = 0
                                    for r in rows {
                                        for dx in -radius...radius {
                                            var v = SIMD8<Float>()
                                            if x + dx >= 0, x + dx + 7 < w {
                                                v = UnsafeRawPointer(inp.baseAddress! + r + x + dx)
                                                    .loadUnaligned(as: SIMD8<Float>.self)
                                            } else {
                                                for l in 0..<8 { v[l] = inp[r + min(max(x + l + dx, 0), w - 1)] }
                                            }
                                            window[k] = v
                                            k += 1
                                        }
                                    }
                                    let m = median25(window)
                                    let o = plane + (y - top) * w
                                    for l in 0..<min(8, w - x) { outp[o + x + l] = m[l] }
                                    x += 8
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
        // Back to RGB with the original luminance.
        for y in rows {
            for x in 0..<w {
                let p = load(y * w + x)
                let l = max(lum(p.x, p.y, p.z), 1e-5)
                let o = (y - top) * w + x
                let rgb = SIMD3(exp(ratio[o]), exp(ratio[n * w + o]), exp(ratio[2 * n * w + o])) * l
                store(y * w + x, rgb * (l / max(lum(rgb.x, rgb.y, rgb.z), 1e-5)))
            }
        }
    }

    /// Compare-exchanges that put the median (index 12) of 25 values in place: Batcher's
    /// odd-even merge sort for 25 wires, pruned to the comparators the middle wire depends on.
    static let medianNetwork: [(Int, Int)] = {
        let n = 25
        var all: [(Int, Int)] = []
        var p = 1
        while p < n {
            var k = p
            while k >= 1 {
                var j = k % p
                while j <= n - 1 - k {
                    for i in 0...min(k - 1, n - j - k - 1) where (i + j) / (2 * p) == (i + j + k) / (2 * p) {
                        all.append((i + j, i + j + k))
                    }
                    j += 2 * k
                }
                k /= 2
            }
            p *= 2
        }
        var needed: Set<Int> = [n / 2]
        var kept: [(Int, Int)] = []
        for c in all.reversed() where needed.contains(c.0) || needed.contains(c.1) {
            kept.append(c)
            needed.insert(c.0)
            needed.insert(c.1)
        }
        return kept.reversed()
    }()

    /// The medians of 8 windows of 25 at once, branchless. Reorders `v`.
    @inline(__always) static func median25(_ v: UnsafeMutablePointer<SIMD8<Float>>) -> SIMD8<Float> {
        networkPairs.withUnsafeBufferPointer { pairs in
            var i = 0
            while i < pairs.count {
                let a = pairs[i], b = pairs[i + 1]
                let x = v[a], y = v[b]
                v[a] = simd_min(x, y)
                v[b] = simd_max(x, y)
                i += 2
            }
        }
        return v[12]
    }

    /// `medianNetwork` flattened (a, b, a, b, …) for the inner loop.
    private static let networkPairs: [Int] = medianNetwork.flatMap { [$0.0, $0.1] }

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
