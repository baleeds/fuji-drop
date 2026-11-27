import CoreGraphics
import Foundation
import simd
import Vision

/// Linear camera-native RGB with what a linear DNG needs: a merge (half floats, 1.0 = the
/// brightest value) or a single frame (16-bit integers, 65535 = sensor saturation).
public struct LinearImage: @unchecked Sendable {
    public enum Samples: Sendable {
        case half([Float16])
        case integer([UInt16])

        var isFloat: Bool { if case .half = self { return true } else { return false } }
    }

    public var width: Int
    public var height: Int
    /// Interleaved camera-native RGB (not white-balanced).
    public var samples: Samples
    /// The DNG's default crop (pixels).
    public var crop: (x: Int, y: Int, width: Int, height: Int)
    /// As-shot white-balance multipliers (R, G, B).
    public var wb: [Float]
    /// XYZ (D65) → camera, 3×3 row-major.
    public var camXYZ: [Float]
    public var make: String
    public var model: String
    /// ImageIO properties of the source (reference) RAF, for EXIF.
    public var properties: [String: Any]

    public init(width: Int, height: Int, samples: Samples, crop: (x: Int, y: Int, width: Int, height: Int),
                wb: [Float], camXYZ: [Float], make: String, model: String, properties: [String: Any]) {
        self.width = width
        self.height = height
        self.samples = samples
        self.crop = crop
        self.wb = wb
        self.camXYZ = camXYZ
        self.make = make
        self.model = model
        self.properties = properties
    }
}

/// A merged bracket: linear camera-native RGB, ready for a linear DNG.
public struct MergedImage: @unchecked Sendable {
    public var width: Int
    public var height: Int
    /// Interleaved camera-native RGB (not white-balanced), scaled so the brightest value is 1.
    public var pixels: [Float16]
    /// The area every frame covers after alignment (pixels), for the DNG's default crop.
    public var crop: (x: Int, y: Int, width: Int, height: Int)
    /// The reference frame's as-shot white-balance multipliers (R, G, B).
    public var wb: [Float]
    /// XYZ (D65) → camera, 3×3 row-major.
    public var camXYZ: [Float]
    public var make: String
    public var model: String
    /// The reference frame's ImageIO properties (EXIF, TIFF), for the outputs' metadata.
    public var properties: [String: Any]
    /// What 1.0 in `pixels` is, in units of the reference frame's sensor saturation: the
    /// merge divided by this. log2 of it is roughly how much darker the merged data renders
    /// than the reference frame at the same exposure.
    public var scale: Float
    /// One line per frame (scale, shift), for the log.
    public var report: [String]

    /// The same pixels (shared, not copied) as a DNG source.
    public var linear: LinearImage {
        LinearImage(width: width, height: height, samples: .half(pixels), crop: crop, wb: wb, camXYZ: camXYZ,
                    make: make, model: model, properties: properties)
    }
}

/// Merges an exposure bracket into one linear image (see docs/HDR-PLAN.md, step 3).
///
/// All in camera-native linear light, normalized to the reference (middle) exposure, in
/// horizontal strips spread over the cores, so memory stays at the frames plus the output:
/// 1. Normalize each frame by its exposure (EXIF), refined by the median ratio to the
///    reference over mid-tones, since shutter speeds aren't exact.
/// 2. Align with a Vision homography on half-size luminance; tripod shots (< 0.5 px) skip it.
///    Warping is bilinear, done while merging, so no warped copies are kept.
/// 3. Weight: 1 below 80 % of clip falling to 0 at 95 % (max channel, dilated 2 px), times
///    the light gathered (t / N²), so brighter frames win in the shadows.
/// 4. Deghost on an 8× smaller luminance grid (noise-robust, and its bilinear upsampling
///    smooths the masks): a frame more than ½ stop from the reference drops out; where the
///    reference is clipped, the shortest frame is the anchor instead.
/// 5. Weighted average, then the false-colour cleanup (`ColorCleanup`).
public enum HDRMerger {
    public struct Options: Sendable {
        /// Saturation weight is 1 below this fraction of clip, 0 at `saturationEnd`.
        public var saturationStart: Float = 0.80
        public var saturationEnd: Float = 0.95
        /// A frame differing from the anchor by more than this (stops) is a ghost there.
        public var ghostStops: Float = 0.5
        /// Alignment shifts below this (full-resolution pixels) are ignored (tripod).
        public var minShift: Float = 0.5
        public var align = true
        public var cleanup = true
        public init() {}
    }

    public enum MergeError: LocalizedError {
        case notEnoughFrames
        case sizeMismatch
        case missingExposure

        public var errorDescription: String? {
            switch self {
            case .notEnoughFrames: return "A bracket needs at least two frames"
            case .sizeMismatch: return "The bracket's frames have different sizes"
            case .missingExposure: return "A frame has no exposure information"
            }
        }
    }

    /// Lowres grid block size (pixels).
    static let block = 8
    /// Rows per strip.
    static let strip = 64

    public static func merge(_ frames: [XTransImage], reference: Int, options: Options = Options()) throws -> MergedImage {
        guard frames.count >= 2, frames.indices.contains(reference) else { throw MergeError.notEnoughFrames }
        let w = frames[0].width, h = frames[0].height
        guard frames.allSatisfy({ $0.width == w && $0.height == h }) else { throw MergeError.sizeMismatch }
        let exposures = try frames.map { f -> Exposure in
            guard let e = f.exposure else { throw MergeError.missingExposure }
            return e
        }
        let ref = frames[reference]

        // 1. Exposure relative to the reference, from EXIF (refined after alignment).
        var gain = exposures.map { Float(pow(2, $0.stops(relativeTo: exposures[reference]))) }
        // Light gathered (shot noise): brighter frames are cleaner.
        let photons = exposures.map { Float($0.time / ($0.fNumber * $0.fNumber)) }
        let photonWeight = photons.map { $0 / (photons.max() ?? 1) }

        let grids = frames.map { LowRes($0) }

        // 2. Alignment: a sampling transform per frame, reference pixel → frame pixel.
        var warps = [simd_float3x3?](repeating: nil, count: frames.count)
        var report: [String] = []
        if options.align {
            let refGray = halfGray(ref, gain: 1, exposureLevel: grids[reference].typical)
            for k in frames.indices where k != reference {
                let gray = halfGray(frames[k], gain: gain[k], exposureLevel: grids[reference].typical)
                if let refGray, let gray, let m = homography(floating: gray, reference: refGray, fullHeight: h) {
                    let shift = maxShift(m, width: w, height: h)
                    if shift >= options.minShift { warps[k] = m }
                    report.append(String(format: "frame %d: shift %.1f px%@", k, shift, warps[k] == nil ? " (ignored)" : ""))
                } else {
                    report.append("frame \(k): alignment failed, merged unaligned")
                }
            }
        }

        // Refine each frame's gain with the median ratio over mid-tones, both unclipped.
        let warpedGrids = frames.indices.map { k in grids[k].warped(by: warps[k], into: grids[reference]) }
        for k in frames.indices where k != reference {
            var ratios: [Float] = []
            let a = warpedGrids[k], r = grids[reference]
            for i in r.lum.indices where !a.clipped[i] && !r.clipped[i] && a.valid[i] {
                let x = a.lum[i], y = r.lum[i]
                if x > 0.02, x < 0.6, y > 0.02, y < 0.6 { ratios.append(x / y) }
            }
            if ratios.count > 200 {
                ratios.sort()
                let measured = ratios[ratios.count / 2]
                // Trust EXIF if the measurement is wildly off (e.g. a scene that changed).
                if abs(log2(measured / gain[k])) < 1 { gain[k] = measured }
            }
            report.append(String(format: "frame %d: %.2f stops vs reference", k, log2(gain[k])))
        }

        // 4. Ghost masks on the grid.
        let darkest = exposures.indices.min { gain[$0] < gain[$1] }!
        let ghosts = ghostMasks(warpedGrids, reference: reference, darkest: darkest, gain: gain, options: options)

        // Pixels every frame covers.
        let crop = coverage(warps, width: w, height: h)

        // 3 + 5. Weight and combine, strip by strip.
        var merged = [Float](repeating: 0, count: w * h * 3)
        let strips = (h + strip - 1) / strip
        merged.withUnsafeMutableBufferPointer { out in
            let out = Shared(out)
            DispatchQueue.concurrentPerform(iterations: strips) { s in
                mergeStrip(rows: s * strip..<min(h, (s + 1) * strip), frames: frames, warps: warps,
                           gain: gain, photonWeight: photonWeight, ghosts: ghosts, darkest: darkest,
                           options: options, out: out.value)
            }
        }

        // Brightest value → 1.0.
        let peak = max(merged.withUnsafeBufferPointer { parallelMax($0) }, 1e-6)
        let pixels: [Float16]
        if options.cleanup {
            pixels = ColorCleanup.clean(merged, width: w, height: h, whiteBalance: ref.wb, scale: 1 / peak)
        } else {
            pixels = merged.map { Float16($0 / peak) }
        }
        return MergedImage(width: w, height: h, pixels: pixels, crop: crop, wb: ref.wb, camXYZ: ref.camXYZ,
                           make: ref.make, model: ref.model, properties: ref.properties, scale: peak, report: report)
    }

    // MARK: Strips

    private static func mergeStrip(rows: Range<Int>, frames: [XTransImage], warps: [simd_float3x3?],
                                   gain: [Float], photonWeight: [Float], ghosts: [GhostMask?], darkest: Int,
                                   options: Options, out: UnsafeMutableBufferPointer<Float>) {
        let w = frames[0].width, h = frames[0].height
        let margin = 2
        let top = max(0, rows.lowerBound - margin), bottom = min(h, rows.upperBound + margin)
        let n = (bottom - top) * w
        // Per frame: sampled RGB (camera-native, normalized to the reference exposure), the
        // saturation measure (max white-balanced channel, 0…1), and whether it's inside the frame.
        var values = [[Float]](repeating: [], count: frames.count)
        var sat = [[Float]](repeating: [], count: frames.count)
        var inside = [[Bool]](repeating: [], count: frames.count)
        for k in frames.indices {
            var v = [Float](repeating: 0, count: n * 3)
            var m = [Float](repeating: 1, count: n)
            var ok = [Bool](repeating: false, count: n)
            let f = frames[k]
            let norm = (0..<3).map { 1 / (f.wb[$0] * 65535 * gain[k]) }
            f.pixels.withUnsafeBufferPointer { px in
                for y in top..<bottom {
                    for x in 0..<w {
                        let o = (y - top) * w + x
                        var r: Float, g: Float, b: Float
                        if let warp = warps[k] {
                            let p = warp * SIMD3<Float>(Float(x), Float(y), 1)
                            let sx = p.x / p.z, sy = p.y / p.z
                            guard sx >= 0, sy >= 0, sx <= Float(w - 1), sy <= Float(h - 1) else { continue }
                            (r, g, b) = bilinear(px, w, h, sx, sy)
                        } else {
                            let i = (y * w + x) * 3
                            r = Float(px[i]); g = Float(px[i + 1]); b = Float(px[i + 2])
                        }
                        ok[o] = true
                        m[o] = max(r, g, b) / 65535
                        v[o * 3] = r * norm[0]; v[o * 3 + 1] = g * norm[1]; v[o * 3 + 2] = b * norm[2]
                    }
                }
            }
            values[k] = v
            sat[k] = dilate(m, width: w, height: bottom - top, radius: margin)
            inside[k] = ok
        }

        let span = options.saturationEnd - options.saturationStart
        for y in rows {
            for x in 0..<w {
                let o = (y - top) * w + x
                var sum = SIMD3<Float>(repeating: 0), total: Float = 0
                for k in frames.indices where inside[k][o] {
                    var weight = photonWeight[k] * min(max((options.saturationEnd - sat[k][o]) / span, 0), 1)
                    if weight > 0, let ghost = ghosts[k] { weight *= ghost.value(x: x, y: y) }
                    guard weight > 0 else { continue }
                    let v = values[k]
                    sum += weight * SIMD3(v[o * 3], v[o * 3 + 1], v[o * 3 + 2])
                    total += weight
                }
                let result: SIMD3<Float>
                if total > 1e-6 {
                    result = sum / total
                } else {
                    // Clipped everywhere (or covered by no frame): the shortest exposure.
                    let k = inside[darkest][o] ? darkest : frames.indices.first { inside[$0][o] }
                    if let k {
                        let v = values[k]
                        result = SIMD3(v[o * 3], v[o * 3 + 1], v[o * 3 + 2])
                    } else {
                        result = .zero
                    }
                }
                let i = (y * w + x) * 3
                out[i] = result.x; out[i + 1] = result.y; out[i + 2] = result.z
            }
        }
    }

    @inline(__always)
    private static func bilinear(_ px: UnsafeBufferPointer<UInt16>, _ w: Int, _ h: Int,
                                 _ x: Float, _ y: Float) -> (Float, Float, Float) {
        let x0 = min(Int(x), w - 2), y0 = min(Int(y), h - 2)
        let fx = x - Float(x0), fy = y - Float(y0)
        let i00 = (y0 * w + x0) * 3, i01 = i00 + 3, i10 = i00 + w * 3, i11 = i10 + 3
        func ch(_ c: Int) -> Float {
            let top = Float(px[i00 + c]) * (1 - fx) + Float(px[i01 + c]) * fx
            let bottom = Float(px[i10 + c]) * (1 - fx) + Float(px[i11 + c]) * fx
            return top * (1 - fy) + bottom * fy
        }
        return (ch(0), ch(1), ch(2))
    }

    /// Max filter with a (2r+1)² square, separable, clamped at the edges.
    static func dilate(_ m: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var tmp = m
        for y in 0..<height {
            for x in 0..<width {
                var v: Float = 0
                for dx in -radius...radius { v = max(v, m[y * width + min(max(x + dx, 0), width - 1)]) }
                tmp[y * width + x] = v
            }
        }
        var out = tmp
        for y in 0..<height {
            for x in 0..<width {
                var v: Float = 0
                for dy in -radius...radius { v = max(v, tmp[min(max(y + dy, 0), height - 1) * width + x]) }
                out[y * width + x] = v
            }
        }
        return out
    }

    private static func parallelMax(_ a: UnsafeBufferPointer<Float>) -> Float {
        let parts = 16
        var maxima = [Float](repeating: 0, count: parts)
        maxima.withUnsafeMutableBufferPointer { m in
            let m = Shared(m)
            DispatchQueue.concurrentPerform(iterations: parts) { p in
                let lo = a.count * p / parts, hi = a.count * (p + 1) / parts
                var v: Float = 0
                for i in lo..<hi { v = max(v, a[i]) }
                m.value[p] = v
            }
        }
        return maxima.max() ?? 0
    }

    // MARK: Low-resolution grid

    /// Block averages of a frame (white-balanced RGB and luminance, 0…1 of clip) and which
    /// blocks have a clipped pixel. Used for the exposure refinement and the ghost masks.
    struct LowRes {
        let gw: Int, gh: Int
        var lum: [Float]
        /// 3 per block.
        var rgb: [Float]
        var clipped: [Bool]
        var valid: [Bool]

        init(_ f: XTransImage) {
            let b = HDRMerger.block
            gw = max(1, f.width / b); gh = max(1, f.height / b)
            var rgb = [Float](repeating: 0, count: gw * gh * 3)
            var clipped = [Bool](repeating: false, count: gw * gh)
            let gw = gw, gh = gh
            let clip = UInt16(0.95 * 65535)
            rgb.withUnsafeMutableBufferPointer { m in
                clipped.withUnsafeMutableBufferPointer { c in
                    f.pixels.withUnsafeBufferPointer { px in
                        let m = Shared(m), c = Shared(c)
                        DispatchQueue.concurrentPerform(iterations: gh) { by in
                            for bx in 0..<gw {
                                var sum = SIMD3<Float>(repeating: 0)
                                var anyClip = false
                                for y in by * b..<(by + 1) * b {
                                    for x in bx * b..<(bx + 1) * b {
                                        let i = (y * f.width + x) * 3
                                        let r = px[i], g = px[i + 1], bl = px[i + 2]
                                        if max(r, g, bl) >= clip { anyClip = true }
                                        sum += SIMD3(Float(r), Float(g), Float(bl))
                                    }
                                }
                                sum /= Float(b * b) * 65535
                                let o = by * gw + bx
                                m.value[o * 3] = sum.x; m.value[o * 3 + 1] = sum.y; m.value[o * 3 + 2] = sum.z
                                c.value[o] = anyClip
                            }
                        }
                    }
                }
            }
            self.rgb = rgb
            self.lum = (0..<gw * gh).map { (rgb[$0 * 3] + 2 * rgb[$0 * 3 + 1] + rgb[$0 * 3 + 2]) / 4 }
            self.clipped = clipped
            valid = [Bool](repeating: true, count: gw * gh)
        }

        /// The median block luminance, to set the brightness of the alignment images.
        var typical: Float {
            let sorted = lum.sorted()
            return sorted.isEmpty ? 0.18 : max(sorted[sorted.count / 2], 1e-4)
        }

        /// This grid resampled into `reference`'s geometry (nearest block) through `warp`.
        func warped(by warp: simd_float3x3?, into reference: LowRes) -> LowRes {
            guard let warp else { return self }
            var out = self
            let b = Float(HDRMerger.block)
            for by in 0..<gh {
                for bx in 0..<gw {
                    let p = warp * SIMD3<Float>((Float(bx) + 0.5) * b, (Float(by) + 0.5) * b, 1)
                    let sx = Int((p.x / p.z / b).rounded(.down)), sy = Int((p.y / p.z / b).rounded(.down))
                    let o = by * gw + bx
                    guard sx >= 0, sy >= 0, sx < gw, sy < gh else {
                        out.valid[o] = false
                        continue
                    }
                    let so = sy * gw + sx
                    out.lum[o] = lum[so]
                    out.rgb[o * 3] = rgb[so * 3]; out.rgb[o * 3 + 1] = rgb[so * 3 + 1]; out.rgb[o * 3 + 2] = rgb[so * 3 + 2]
                    out.clipped[o] = clipped[sy * gw + sx]
                    out.valid[o] = true
                }
            }
            return out
        }
    }

    /// Per-frame weights on the grid (1 keep, 0 ghost), upsampled bilinearly when read.
    struct GhostMask {
        let gw: Int, gh: Int
        let weights: [Float]

        func value(x: Int, y: Int) -> Float {
            let b = Float(HDRMerger.block)
            let gx = min(max((Float(x) + 0.5) / b - 0.5, 0), Float(gw - 1))
            let gy = min(max((Float(y) + 0.5) / b - 0.5, 0), Float(gh - 1))
            let x0 = min(Int(gx), gw - 2 < 0 ? 0 : gw - 2), y0 = min(Int(gy), gh - 2 < 0 ? 0 : gh - 2)
            let x1 = min(x0 + 1, gw - 1), y1 = min(y0 + 1, gh - 1)
            let fx = gx - Float(x0), fy = gy - Float(y0)
            let top = weights[y0 * gw + x0] * (1 - fx) + weights[y0 * gw + x1] * fx
            let bottom = weights[y1 * gw + x0] * (1 - fx) + weights[y1 * gw + x1] * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    static func ghostMasks(_ grids: [LowRes], reference: Int, darkest: Int, gain: [Float],
                           options: Options) -> [GhostMask?] {
        let r = grids[reference]
        let floor: Float = 0.003
        return grids.indices.map { k -> GhostMask? in
            guard k != reference else { return nil }
            let g = grids[k]
            var keep = [Float](repeating: 1, count: r.lum.count)
            var any = false
            for i in keep.indices where g.valid[i] && !g.clipped[i] {
                // Compare with the reference, or where that's clipped, with the shortest frame.
                let anchor = r.clipped[i] ? darkest : reference
                guard anchor != k, grids[anchor].valid[i], !grids[anchor].clipped[i] else { continue }
                // Per channel, not just luminance: a leg moving over ferns can keep the
                // brightness and change only the colour.
                var differs = false
                for c in 0..<3 {
                    let a = grids[anchor].rgb[i * 3 + c] / gain[anchor], v = g.rgb[i * 3 + c] / gain[k]
                    guard max(a, v) > floor else { continue }
                    if abs(log2(max(v, 1e-6) / max(a, 1e-6))) > options.ghostStops { differs = true }
                }
                if differs {
                    keep[i] = 0
                    any = true
                }
            }
            guard any else { return nil }
            // Grow ghosts by one block, so the edges of moving things go too.
            var grown = keep
            for by in 0..<r.gh {
                for bx in 0..<r.gw where keep[by * r.gw + bx] == 0 {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let y = by + dy, x = bx + dx
                            if x >= 0, y >= 0, x < r.gw, y < r.gh { grown[y * r.gw + x] = 0 }
                        }
                    }
                }
            }
            return GhostMask(gw: r.gw, gh: r.gh, weights: grown)
        }
    }

    // MARK: Alignment

    /// Half-size gray image of a frame for Vision: luminance normalized to the reference
    /// exposure, brightened so the scene's median sits near mid-grey, gamma-encoded.
    static func halfGray(_ f: XTransImage, gain: Float, exposureLevel: Float) -> CGImage? {
        let hw = f.width / 2, hh = f.height / 2
        guard hw > 16, hh > 16 else { return nil }
        let k = 0.18 / exposureLevel / gain / (4 * 4 * 65535)
        var gray = [UInt8](repeating: 0, count: hw * hh)
        gray.withUnsafeMutableBufferPointer { out in
            f.pixels.withUnsafeBufferPointer { px in
                let out = Shared(out)
                DispatchQueue.concurrentPerform(iterations: hh) { y in
                    for x in 0..<hw {
                        var s: Float = 0
                        for dy in 0..<2 {
                            for dx in 0..<2 {
                                let i = ((2 * y + dy) * f.width + 2 * x + dx) * 3
                                s += Float(px[i]) + 2 * Float(px[i + 1]) + Float(px[i + 2])
                            }
                        }
                        out.value[y * hw + x] = UInt8(min(max((s * k).squareRoot(), 0), 1) * 255)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(width: hw, height: hh, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: hw,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The sampling transform (full-resolution reference pixel → floating pixel, top-left
    /// origin) from a Vision homography between half-size images.
    ///
    /// Vision's `warpTransform` maps the floating image onto the reference in bottom-left
    /// origin coordinates (checked with a synthetic shift). So: pixel centre → half size →
    /// flip y → inverse warp → flip back → full size → pixel index.
    static func homography(floating: CGImage, reference: CGImage, fullHeight: Int) -> simd_float3x3? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: floating, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }
        let warp = observation.warpTransform
        guard abs(warp.determinant) > 1e-6 else { return nil }
        let hh = Float(reference.height)
        // Column-major simd matrices: init(rows:) for readability.
        let toHalf = simd_float3x3(rows: [SIMD3(0.5, 0, 0.25), SIMD3(0, 0.5, 0.25), SIMD3(0, 0, 1)]) // (x+0.5)/2
        let flip = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, hh), SIMD3(0, 0, 1)])
        let toFull = simd_float3x3(rows: [SIMD3(2, 0, -0.5), SIMD3(0, 2, -0.5), SIMD3(0, 0, 1)]) // 2x − 0.5
        _ = fullHeight
        return toFull * flip * warp.inverse * flip * toHalf
    }

    /// Largest displacement of the corners and centre under a sampling transform.
    static func maxShift(_ m: simd_float3x3, width: Int, height: Int) -> Float {
        let w = Float(width - 1), h = Float(height - 1)
        return [SIMD2<Float>(0, 0), SIMD2(w, 0), SIMD2(0, h), SIMD2(w, h), SIMD2(w / 2, h / 2)].map { p in
            let q = m * SIMD3(p.x, p.y, 1)
            return simd_length(SIMD2(q.x / q.z, q.y / q.z) - p)
        }.max() ?? 0
    }

    /// The rectangle of reference pixels every frame covers (conservative, from the corners).
    static func coverage(_ warps: [simd_float3x3?], width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        var x0: Float = 0, y0: Float = 0, x1 = Float(width - 1), y1 = Float(height - 1)
        for case let m? in warps {
            // Where the frame's own corners land in the reference.
            let inv = m.inverse
            func land(_ x: Float, _ y: Float) -> SIMD2<Float> {
                let q = inv * SIMD3(x, y, 1)
                return SIMD2(q.x / q.z, q.y / q.z)
            }
            let w = Float(width - 1), h = Float(height - 1)
            let tl = land(0, 0), tr = land(w, 0), bl = land(0, h), br = land(w, h)
            x0 = max(x0, tl.x, bl.x); x1 = min(x1, tr.x, br.x)
            y0 = max(y0, tl.y, tr.y); y1 = min(y1, bl.y, br.y)
        }
        // Whole pixels, even origin and size (keeps any chroma alignment simple for readers).
        let ix0 = Int(x0.rounded(.up) + 1) & ~1, iy0 = Int(y0.rounded(.up) + 1) & ~1
        let ix1 = Int(x1.rounded(.down)) - 1, iy1 = Int(y1.rounded(.down)) - 1
        let cw = max(2, (ix1 - ix0 + 1) & ~1), ch = max(2, (iy1 - iy0 + 1) & ~1)
        if warps.allSatisfy({ $0 == nil }) { return (0, 0, width, height) }
        return (ix0, iy0, min(cw, width - ix0), min(ch, height - iy0))
    }
}
