import CoreGraphics
import Foundation
import simd

/// Renders linear camera RGB (white-balanced, 1.0 = sensor saturation) to an 8-bit sRGB
/// image: camera colour → linear sRGB through the camera's matrix, an exposure, a filmic tone
/// curve, then the sRGB transfer curve. Used for the JPEG paired with a DNG save, so the photo
/// people see and share comes from the same LibRaw decode as the DNG, not Apple's RAW filter.
public enum LinearRenderer {
    /// Tone curves tried against the camera's own JPEGs (see `LinearRendererTests`).
    public enum Curve: String, CaseIterable, Sendable {
        /// No curve: linear sRGB clipped at 1.
        case clip
        /// Narkowicz's ACES fit, per channel: contrasty, saturated, strong shoulder.
        case aces
        /// Hable's filmic curve (Uncharted 2), per channel, white point 11.2: softer.
        case hable
        /// A log-space S-curve on luminance with colour kept: gentle, hue-preserving.
        case logS
    }

    /// Closest to the camera's own JPEGs: on 16 of the owner's X-T1 frames (forest, portraits,
    /// mountains), mean difference 8.4 levels vs 11.4 for `logS`, 14.9 `clip`, 16.3 `hable`.
    public static let defaultCurve = Curve.aces

    /// LibRaw's way (`convert_to_rgb`): camera ← sRGB is `camXYZ · xyzRGB` with rows normalized
    /// to sum to 1 (so white-balanced white stays white); invert it.
    public static func cameraToSRGB(_ camXYZ: [Float]) -> simd_float3x3 {
        let xyzRGB = simd_float3x3(rows: [SIMD3(0.412453, 0.357580, 0.180423),
                                          SIMD3(0.212671, 0.715160, 0.072169),
                                          SIMD3(0.019334, 0.119193, 0.950227)])
        let camXYZm = simd_float3x3(rows: [SIMD3(camXYZ[0], camXYZ[1], camXYZ[2]),
                                           SIMD3(camXYZ[3], camXYZ[4], camXYZ[5]),
                                           SIMD3(camXYZ[6], camXYZ[7], camXYZ[8])])
        let camRGB = camXYZm * xyzRGB
        var rows = (0..<3).map { r in SIMD3(camRGB[0][r], camRGB[1][r], camRGB[2][r]) }
        for r in 0..<3 {
            let sum = rows[r].x + rows[r].y + rows[r].z
            if abs(sum) > 1e-6 { rows[r] /= sum }
        }
        let normalized = simd_float3x3(rows: rows)
        guard abs(normalized.determinant) > 1e-8 else { return matrix_identity_float3x3 }
        return normalized.inverse
    }

    /// Renders `width × height` pixels from `load(pixel index)`, downsampled by `factor` (box
    /// average in linear light), at `exposure` stops.
    /// - Parameter balance: per-channel gains on linear sRGB before the tone curve (see
    ///   `matchLook`); 1 keeps the as-shot white balance.
    public static func render(width: Int, height: Int, camXYZ: [Float], exposure: Float,
                              balance: SIMD3<Float> = .one, curve: Curve = defaultCurve, factor: Int = 1,
                              load: (Int) -> SIMD3<Float>) -> CGImage? {
        let ow = width / factor, oh = height / factor
        guard ow > 0, oh > 0 else { return nil }
        let m = cameraToSRGB(camXYZ)
        let gain = balance * pow(2, exposure)
        let encode = sRGBTable
        // Rendered straight into the buffer the image owns (freed with it): no copy.
        let bytes = ow * oh * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
        let out = SendableBox(buffer)
        DispatchQueue.concurrentPerform(iterations: oh) { y in
            for x in 0..<ow {
                var sum = SIMD3<Float>(repeating: 0)
                for dy in 0..<factor {
                    for dx in 0..<factor { sum += load((y * factor + dy) * width + x * factor + dx) }
                }
                let cam = sum / Float(factor * factor)
                let lin = tone(m * cam * gain, curve)
                let o = (y * ow + x) * 4
                out.value[o] = encode[index(lin.x)]
                out.value[o + 1] = encode[index(lin.y)]
                out.value[o + 2] = encode[index(lin.z)]
                out.value[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer, size: bytes, releaseData: { _, data, _ in
            data.deallocate()
        }) else {
            buffer.deallocate()
            return nil
        }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Exposure (stops) at which a render's overall brightness matches `reference` (the
    /// camera's JPEG), from small renders. Three passes, since the curve bends the estimate.
    public static func matchExposure(width: Int, height: Int, camXYZ: [Float], reference: CGImage,
                                     balance: SIMD3<Float> = .one, curve: Curve = defaultCurve,
                                     load: (Int) -> SIMD3<Float>) -> Float {
        guard let target = GrayImage(reference, maxSide: 256) else { return 0 }
        let factor = max(1, max(width, height) / 512)
        var ev: Float = 0
        for _ in 0..<3 {
            guard let small = render(width: width, height: height, camXYZ: camXYZ, exposure: ev, balance: balance,
                                     curve: curve, factor: factor, load: load),
                  let probe = GrayImage(small, maxSide: 256) else { break }
            ev += Brightness.stops(toMatch: target, from: probe)
        }
        return min(max(ev, -3), 5)
    }

    /// Exposure and colour balance at which a render looks like `reference` (the camera's
    /// JPEG): the brightness match above, plus per-channel gains so midtones have the same
    /// average colour. Fuji's JPEGs run warmer than a neutral render (measured b* +1 to +6
    /// on the owner's frames, most under tungsten), so without this the photo reads bluer
    /// than the camera showed it. Only midtone blocks count (a merge's recovered highlights
    /// and lifted shadows legitimately differ); gains keep luminance and stay within ±25 %.
    public static func matchLook(width: Int, height: Int, camXYZ: [Float], reference: CGImage,
                                 load: (Int) -> SIMD3<Float>) -> (exposure: Float, balance: SIMD3<Float>) {
        var balance = SIMD3<Float>.one
        var ev = matchExposure(width: width, height: height, camXYZ: camXYZ, reference: reference, load: load)
        guard let target = blockColours(reference) else { return (ev, balance) }
        let factor = max(1, max(width, height) / 512)
        for _ in 0..<2 {
            guard let small = render(width: width, height: height, camXYZ: camXYZ, exposure: ev, balance: balance,
                                     factor: factor, load: load),
                  let ours = blockColours(small) else { break }
            // Median per-channel ratio over blocks that are midtones in both.
            var ratios: [[Float]] = [[], [], []]
            for (a, b) in zip(target, ours) {
                let la = luminance(a), lb = luminance(b)
                guard la > 0.03, la < 0.6, lb > 0.03, lb < 0.6, b.min() > 1e-3 else { continue }
                for c in 0..<3 { ratios[c].append(a[c] / b[c]) }
            }
            guard ratios[0].count >= 20 else { break }
            var r = SIMD3<Float>(repeating: 1)
            for c in 0..<3 { let sorted = ratios[c].sorted(); r[c] = sorted[sorted.count / 2] }
            balance *= r / luminance(r) // keep brightness: exposure is matched separately
            balance = balance.clamped(lowerBound: SIMD3(repeating: 0.8), upperBound: SIMD3(repeating: 1.25))
            ev = matchExposure(width: width, height: height, camXYZ: camXYZ, reference: reference, balance: balance, load: load)
        }
        return (ev, balance)
    }

    @inline(__always) static func luminance(_ c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

    /// Average linear-sRGB colour of each block of a 24 × 16 grid.
    static func blockColours(_ image: CGImage) -> [SIMD3<Float>]? {
        let gw = 24, gh = 16
        var px = [Float](repeating: 0, count: gw * gh * 4)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &px, width: gw, height: gh, bitsPerComponent: 32, bytesPerRow: gw * 16,
                                  space: CGColorSpace(name: CGColorSpace.linearSRGB)!, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        return (0..<gw * gh).map { SIMD3(px[$0 * 4], px[$0 * 4 + 1], px[$0 * 4 + 2]) }
    }

    // MARK: Curves

    @inline(__always) static func tone(_ c: SIMD3<Float>, _ curve: Curve) -> SIMD3<Float> {
        let v = c.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1e4))
        switch curve {
        case .clip:
            return v
        case .aces:
            let a: Float = 2.51, b: Float = 0.03, cc: Float = 2.43, d: Float = 0.59, e: Float = 0.14
            return (v * (a * v + b)) / (v * (cc * v + d) + e)
        case .hable:
            let white: Float = 11.2
            // Pre-scale so mid-grey lands near where the other curves put it.
            return hable(v * 2) / hable(SIMD3(repeating: white))
        case .logS:
            let l = 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z
            guard l > 1e-6 else { return .zero }
            // Contrast 1.2 around mid-grey in log2, with a soft shoulder towards 1.
            let x = log2(l / 0.18)
            var t = 0.18 * pow(2, 1.2 * x)
            t = t / (1 + t / 4) * 1.25
            return v * (min(t, 1) / l)
        }
    }

    @inline(__always) private static func hable(_ x: SIMD3<Float>) -> SIMD3<Float> {
        let a: Float = 0.15, b: Float = 0.50, c: Float = 0.10, d: Float = 0.20, e: Float = 0.02, f: Float = 0.30
        return ((x * (a * x + c * b) + d * e) / (x * (a * x + b) + d * f)) - e / f
    }

    // MARK: sRGB encoding

    private static let tableSize = 16384
    /// Linear 0…1 → 8-bit sRGB, sampled finely enough for 8-bit output.
    private static let sRGBTable: [UInt8] = (0..<tableSize).map { i in
        let c = Float(i) / Float(tableSize - 1)
        let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        return UInt8(min(max(s * 255 + 0.5, 0), 255))
    }

    @inline(__always) private static func index(_ v: Float) -> Int {
        Int(min(max(v, 0), 1) * Float(tableSize - 1) + 0.5)
    }
}
