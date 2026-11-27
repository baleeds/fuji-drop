import CoreImage
import Foundation
import ImageIO

/// The whole HDR merge for a bracket: decode each RAF (LibRaw, one at a time), merge, write
/// a linear DNG and a JPEG rendered from it. Blocking and heavy (several seconds, several
/// hundred MB): run it on a background queue.
public enum HDRPipeline {
    public struct Output: Sendable {
        public var dng: URL
        public var jpeg: URL
        /// Log lines: timings and per-frame alignment and exposure.
        public var report: [String]
    }

    /// - Parameters:
    ///   - raws: the bracket's RAFs, any order.
    ///   - previews: each RAF's embedded camera JPEG (same order), if available. The reference
    ///     frame's sets the DNG's BaselineExposure, so the merge opens as bright as the camera
    ///     showed the middle exposure (this also covers DR200/DR400, see `RAWRenderer`).
    ///   - name: file name without extension, e.g. `DSCF2729-HDR`.
    public static func run(raws: [URL], previews: [URL?], name: String, into directory: URL,
                           options: HDRMerger.Options = HDRMerger.Options(),
                           progress: (String) -> Void = { _ in }) throws -> Output {
        var report: [String] = []
        var started = Date()
        func lap(_ what: String) {
            let line = String(format: "%@ in %.1f s", what, Date().timeIntervalSince(started))
            report.append(line)
            progress(line)
            started = Date()
        }

        // Decode one after another: each needs a few hundred MB while running.
        var frames: [XTransImage] = []
        for (i, raw) in raws.enumerated() {
            progress("Decoding \(i + 1) of \(raws.count)")
            frames.append(try XTransDecoder.decode(raw))
            lap("Decoded \(raw.lastPathComponent)")
        }
        let exposures = frames.compactMap(\.exposure)
        guard exposures.count == frames.count else { throw HDRMerger.MergeError.missingExposure }
        let reference = BracketFinder.referenceIndex(exposures)

        progress("Merging")
        let merged = try HDRMerger.merge(frames, reference: reference, options: options)
        frames = [] // free the decoded frames before writing
        report += merged.report
        lap("Merged \(raws.count) frames (reference \(raws[reference].lastPathComponent))")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Brightness and preview from a small DNG of the same data: render it the way an
        // editor would, compare with the camera's own JPEG of the reference frame.
        let small = downsample(merged, factor: 4)
        let probeURL = directory.appendingPathComponent("\(name)-probe.dng")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        try DNGWriter.write(small, to: probeURL, baselineExposure: 0, preview: nil)
        let cameraJPEG = previews.indices.contains(reference) ? previews[reference].flatMap(cgImage) : nil
        var baseline = Double(log2(merged.scale))
        if let cameraJPEG, let measured = measureExposure(probeURL, against: cameraJPEG) {
            baseline = Double(measured)
        }
        report.append(String(format: "BaselineExposure %+.2f (data scale %+.2f stops)", baseline, log2(merged.scale)))

        // The JPEG (and the DNG's preview) from the merged data with `LinearRenderer`, like
        // DNG saves: white-balanced, in units of the reference frame's saturation, so the
        // tone curve's shoulder rolls off the highlights the merge recovered.
        let gain = SIMD3(merged.wb[0], merged.wb[1], merged.wb[2]) * merged.scale
        let px = merged.pixels
        let load: (Int) -> SIMD3<Float> = { i in SIMD3(Float(px[i * 3]), Float(px[i * 3 + 1]), Float(px[i * 3 + 2])) * gain }
        let w = merged.width, h = merged.height
        let ev = cameraJPEG.map { LinearRenderer.matchExposure(width: w, height: h, camXYZ: merged.camXYZ, reference: $0, load: load) } ?? 0
        let factor = max(1, (w + 1023) / 1024)
        let preview = LinearRenderer.render(width: w, height: h, camXYZ: merged.camXYZ, exposure: ev, factor: factor,
                                            load: load).flatMap(DNGConverter.rgbPreview)

        progress("Writing DNG")
        let dng = directory.appendingPathComponent("\(name).DNG")
        try DNGWriter.write(merged, to: dng, baselineExposure: baseline, preview: preview)
        lap("Wrote \(dng.lastPathComponent)")

        progress("Rendering JPEG")
        guard let full = LinearRenderer.render(width: w, height: h, camXYZ: merged.camXYZ, exposure: ev, load: load) else {
            throw RAWRenderer.RenderError.cannotRender(name)
        }
        // Cropped to the area every frame covers, like the DNG's default crop.
        let c = merged.crop
        let cropped = full.cropping(to: CGRect(x: c.x, y: c.y, width: c.width, height: c.height)) ?? full
        let jpeg = directory.appendingPathComponent("\(name).JPG")
        try RAWRenderer.writeJPEG(cropped, metadataFrom: raws[reference], to: jpeg)
        lap(String(format: "Rendered %@ (%+.2f EV)", jpeg.lastPathComponent, ev))
        return Output(dng: dng, jpeg: jpeg, report: report)
    }

    // MARK: Helpers

    static func cgImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Box-downsampled copy (no cleanup needed: the data is already clean).
    static func downsample(_ m: MergedImage, factor f: Int) -> MergedImage {
        let w = m.width / f, h = m.height / f
        var px = [Float16](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    var s: Float = 0
                    for dy in 0..<f { for dx in 0..<f { s += Float(m.pixels[((y * f + dy) * m.width + x * f + dx) * 3 + c]) } }
                    px[(y * w + x) * 3 + c] = Float16(s / Float(f * f))
                }
            }
        }
        var out = m
        out.width = w
        out.height = h
        out.pixels = px
        out.crop = (m.crop.x / f, m.crop.y / f, min(m.crop.width / f, w - m.crop.x / f), min(m.crop.height / f, h - m.crop.y / f))
        return out
    }

    /// Stops to add to a DNG's default render so its overall brightness matches `reference`
    /// (Core Image's RAW pipeline, like Photos; see `RAWRenderer.matchExposure`).
    static func measureExposure(_ dng: URL, against reference: CGImage) -> Float? {
        guard let filter = CIRAWFilter(imageURL: dng), let target = GrayImage(reference, maxSide: 256) else { return nil }
        var ev: Float = 0
        for _ in 0..<3 {
            filter.exposure = ev
            guard let image = filter.outputImage,
                  let cg = RAWRenderer.context.createCGImage(image, from: image.extent),
                  let probe = GrayImage(cg, maxSide: 256) else { return nil }
            ev += Brightness.stops(toMatch: target, from: probe)
        }
        return min(max(ev, -4), 8)
    }
}
