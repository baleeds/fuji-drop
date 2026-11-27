import CoreGraphics
import Foundation
import ImageIO

/// Converts one RAF to a linear DNG and a JPEG from the same decode (docs/HDR-PLAN.md, step 3,
/// "Save RAW as DNG"): LibRaw's Markesteijn demosaic plus the false-colour cleanup, written as
/// 16-bit integer LinearRaw with lossless JPEG compression (Core Image can't read Deflate),
/// and a JPEG rendered with `LinearRenderer` instead of Apple's RAW filter. Blocking and heavy:
/// run it on a background queue.
public enum DNGConverter {
    public struct Output: Sendable {
        public var dng: URL
        public var jpeg: URL
        public var report: [String]
    }

    /// - Parameters:
    ///   - preview: the RAF's embedded camera JPEG (the cached preview). The JPEG and the DNG's
    ///     BaselineExposure are matched to its brightness, which also covers DR200/DR400.
    ///   - name: file name without extension, e.g. `DSCF1234`.
    public static func convert(raw: URL, preview: URL?, name: String, into directory: URL,
                               progress: (String) -> Void = { _ in }) throws -> Output {
        var report: [String] = []
        var started = Date()
        func lap(_ what: String) {
            report.append(String(format: "%@ in %.2f s", what, Date().timeIntervalSince(started)))
            started = Date()
        }

        progress("Decoding")
        var frame = try XTransDecoder.decode(raw)
        lap("Decoded")
        let native = ColorCleanup.clean(frame)
        frame.pixels = [] // done with the white-balanced copy
        lap("Cleaned colour")

        let w = frame.width, h = frame.height
        let gain = SIMD3(frame.wb[0], frame.wb[1], frame.wb[2]) / 65535
        // White-balanced, 1.0 = saturation, for rendering.
        let load: (Int) -> SIMD3<Float> = { i in
            SIMD3(Float(native[i * 3]), Float(native[i * 3 + 1]), Float(native[i * 3 + 2])) * gain
        }
        let camera = preview.flatMap { ImageLoading.thumbnail(at: $0, maxPixelSize: 512) }

        progress("Rendering JPEG")
        let ev = camera.map {
            LinearRenderer.matchExposure(width: w, height: h, camXYZ: frame.camXYZ, reference: $0, load: load)
        } ?? 0
        guard let full = LinearRenderer.render(width: w, height: h, camXYZ: frame.camXYZ, exposure: ev, load: load) else {
            throw RAWRenderer.RenderError.cannotRender(name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let jpeg = directory.appendingPathComponent("\(name).JPG")
        try RAWRenderer.writeJPEG(full, metadataFrom: raw, to: jpeg)
        lap(String(format: "Rendered JPEG (%+.2f EV)", ev))

        let image = LinearImage(width: w, height: h, samples: .integer(native), crop: (0, 0, w, h), wb: frame.wb,
                                camXYZ: frame.camXYZ, make: frame.make, model: frame.model, properties: frame.properties)
        // BaselineExposure: what Core Image (Photos) needs to open the DNG as bright as the
        // camera's JPEG, measured on a quarter-size copy.
        var baseline: Double = 0
        if let camera {
            let probe = directory.appendingPathComponent("\(name)-probe.dng")
            defer { try? FileManager.default.removeItem(at: probe) }
            try DNGWriter.write(downsample(image, factor: 4), to: probe, baselineExposure: 0, preview: nil)
            if let measured = HDRPipeline.measureExposure(probe, against: camera) { baseline = Double(measured) }
        }
        let factor = max(1, (w + 1023) / 1024)
        let preview = LinearRenderer.render(width: w, height: h, camXYZ: frame.camXYZ, exposure: ev, factor: factor,
                                            load: load).flatMap(rgbPreview)

        progress("Writing DNG")
        let dng = directory.appendingPathComponent("\(name).DNG")
        try DNGWriter.write(image, to: dng, baselineExposure: baseline, preview: preview, compression: .losslessJPEG)
        lap(String(format: "Wrote DNG (BaselineExposure %+.2f)", baseline))
        return Output(dng: dng, jpeg: jpeg, report: report)
    }

    /// Box-downsampled copy of an integer image.
    static func downsample(_ image: LinearImage, factor f: Int) -> LinearImage {
        guard case .integer(let px) = image.samples else { return image }
        let w = image.width / f, h = image.height / f
        var out = [UInt16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var s = 0
                    for dy in 0..<f { for dx in 0..<f { s += Int(px[((y * f + dy) * image.width + x * f + dx) * 3 + c]) } }
                    out[(y * w + x) * 3 + c] = UInt16(s / (f * f))
                }
            }
        }
        var small = image
        small.width = w
        small.height = h
        small.samples = .integer(out)
        small.crop = (0, 0, w, h)
        return small
    }

    /// An 8-bit RGB preview for IFD0 from a rendered image.
    static func rgbPreview(_ image: CGImage) -> DNGWriter.Preview? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<w * h {
            rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return DNGWriter.Preview(width: w, height: h, rgb: rgb)
    }
}
