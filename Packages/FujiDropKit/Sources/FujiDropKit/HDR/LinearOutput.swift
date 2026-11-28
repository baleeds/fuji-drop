import CoreGraphics
import CoreImage
import Foundation

/// The last step shared by DNG saves and HDR merges: from linear camera RGB, render the JPEG
/// (`LinearRenderer`, brightness and colour matched to the camera's own JPEG; the DNG keeps the
/// as-shot white balance for editing), write the DNG with a
/// preview scaled from that render and a BaselineExposure that makes Core Image (Photos) open
/// it about as bright.
enum LinearOutput {
    struct Files {
        var dng: URL
        var jpeg: URL
        /// The JPEG's exposure and the DNG's BaselineExposure, for the log.
        var report: String
    }

    /// - Parameters:
    ///   - unit: what 1.0 of a sample is in units of sensor saturation (`1 / 65535` for 16-bit
    ///     integers; a merge's `scale` for its half floats).
    ///   - camera: the camera's JPEG of the (reference) frame, any size; nil skips matching.
    ///   - fallbackBaseline: BaselineExposure if it can't be measured.
    ///   - metadataFrom: the RAF whose EXIF the JPEG carries.
    static func write(_ image: LinearImage, unit: Float, camera: CGImage?, fallbackBaseline: Double = 0,
                      metadataFrom raw: URL, name: String, into directory: URL,
                      compression: DNGWriter.Compression) throws -> Files {
        let w = image.width, h = image.height
        let gain = SIMD3(image.wb[0], image.wb[1], image.wb[2]) * unit
        // White-balanced, 1.0 = saturation.
        let load: (Int) -> SIMD3<Float>
        switch image.samples {
        case .half(let px): load = { i in SIMD3(Float(px[i * 3]), Float(px[i * 3 + 1]), Float(px[i * 3 + 2])) * gain }
        case .integer(let px): load = { i in SIMD3(Float(px[i * 3]), Float(px[i * 3 + 1]), Float(px[i * 3 + 2])) * gain }
        }

        let look = camera.map {
            LinearRenderer.matchLook(width: w, height: h, camXYZ: image.camXYZ, reference: $0, load: load)
        } ?? (exposure: 0, balance: .one)
        let ev = look.exposure
        guard let full = LinearRenderer.render(width: w, height: h, camXYZ: image.camXYZ, exposure: ev,
                                               balance: look.balance, load: load) else {
            throw RAWRenderer.RenderError.cannotRender(name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let c = image.crop
        let shown = c == (0, 0, w, h) ? full : full.cropping(to: CGRect(x: c.x, y: c.y, width: c.width, height: c.height)) ?? full
        let jpeg = directory.appendingPathComponent("\(name).JPG")
        try RAWRenderer.writeJPEG(shown, metadataFrom: raw, to: jpeg)

        var baseline = fallbackBaseline
        if let camera {
            let probe = directory.appendingPathComponent("\(name)-probe.dng")
            defer { try? FileManager.default.removeItem(at: probe) }
            try DNGWriter.write(downsample(image, factor: 4), to: probe, baselineExposure: 0, preview: nil)
            if let filter = CIRAWFilter(imageURL: probe) {
                baseline = Double(RAWRenderer.matchExposure(filter, to: camera, passes: 3, range: -4...8, draft: false))
            }
        }

        let dng = directory.appendingPathComponent("\(name).DNG")
        try DNGWriter.write(image, to: dng, baselineExposure: baseline, preview: preview(full, maxSide: 1024),
                            compression: compression)
        let b = look.balance
        return Files(dng: dng, jpeg: jpeg, report: String(format: "JPEG %+.2f EV, balance %.2f/%.2f/%.2f, BaselineExposure %+.2f",
                                                           ev, b.x, b.y, b.z, baseline))
    }

    /// Box-downsampled copy, rows in parallel.
    static func downsample(_ image: LinearImage, factor f: Int) -> LinearImage {
        let w = image.width / f, h = image.height / f
        func shrink<T>(_ px: [T], _ toFloat: (T) -> Float, _ fromFloat: (Float) -> T, zero: T) -> [T] {
            var out = [T](repeating: zero, count: w * h * 3)
            out.withUnsafeMutableBufferPointer { dst in
                px.withUnsafeBufferPointer { src in
                    let dst = SendableBox(dst), src = SendableBox(src)
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            for c in 0..<3 {
                                var s: Float = 0
                                for dy in 0..<f {
                                    for dx in 0..<f { s += toFloat(src.value[((y * f + dy) * image.width + x * f + dx) * 3 + c]) }
                                }
                                dst.value[(y * w + x) * 3 + c] = fromFloat(s / Float(f * f))
                            }
                        }
                    }
                }
            }
            return out
        }
        var small = image
        small.width = w
        small.height = h
        switch image.samples {
        case .half(let px): small.samples = .half(shrink(px, { Float($0) }, { Float16($0) }, zero: 0))
        case .integer(let px): small.samples = .integer(shrink(px, { Float($0) }, { UInt16($0.rounded()) }, zero: 0))
        }
        let c = image.crop
        small.crop = (c.x / f, c.y / f, min(c.width / f, w - c.x / f), min(c.height / f, h - c.y / f))
        return small
    }

    /// The DNG's IFD0 preview: `image` scaled to fit `maxSide`, as 8-bit RGB.
    static func preview(_ image: CGImage, maxSide: Int) -> DNGWriter.Preview? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<w * h {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return DNGWriter.Preview(width: w, height: h, rgb: rgb)
    }
}

/// Times the steps of a pipeline for its log ("Decoded in 2.31 s").
struct Laps {
    private(set) var lines: [String] = []
    private var started = Date()

    mutating func lap(_ what: String) {
        lines.append(String(format: "%@ in %.2f s", what, Date().timeIntervalSince(started)))
        started = Date()
    }
}
