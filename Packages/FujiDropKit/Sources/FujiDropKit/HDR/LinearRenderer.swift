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
    public static func render(width: Int, height: Int, camXYZ: [Float], exposure: Float,
                              curve: Curve = defaultCurve, factor: Int = 1,
                              load: (Int) -> SIMD3<Float>) -> CGImage? {
        let ow = width / factor, oh = height / factor
        guard ow > 0, oh > 0 else { return nil }
        let m = cameraToSRGB(camXYZ)
        let gain = pow(2, exposure)
        let encode = sRGBTable
        var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            let out = Shared(out)
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
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Exposure (stops) at which a render's overall brightness matches `reference` (the
    /// camera's JPEG), from small renders. Three passes, since the curve bends the estimate.
    public static func matchExposure(width: Int, height: Int, camXYZ: [Float], reference: CGImage,
                                     curve: Curve = defaultCurve, load: (Int) -> SIMD3<Float>) -> Float {
        guard let target = GrayImage(reference, maxSide: 256) else { return 0 }
        let factor = max(1, max(width, height) / 512)
        var ev: Float = 0
        for _ in 0..<3 {
            guard let small = render(width: width, height: height, camXYZ: camXYZ, exposure: ev, curve: curve,
                                     factor: factor, load: load),
                  let probe = GrayImage(small, maxSide: 256) else { break }
            ev += Brightness.stops(toMatch: target, from: probe)
        }
        return min(max(ev, -3), 5)
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
