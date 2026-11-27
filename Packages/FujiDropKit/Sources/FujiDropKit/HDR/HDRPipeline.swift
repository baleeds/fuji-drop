import Foundation

/// The whole HDR merge for a bracket: decode each RAF (LibRaw, one at a time), merge, write
/// a linear DNG and a JPEG rendered from the merged data. Blocking and heavy (several
/// seconds, several hundred MB): run it on a background queue.
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
    ///     frame's sets the JPEG's brightness and the DNG's BaselineExposure, so the merge opens
    ///     as bright as the camera showed the middle exposure (this also covers DR200/DR400).
    ///   - name: file name without extension, e.g. `DSCF2729-HDR`.
    public static func run(raws: [URL], previews: [URL?], name: String, into directory: URL,
                           progress: (String) -> Void = { _ in }) throws -> Output {
        var laps = Laps()

        // Decode one after another: each needs a few hundred MB while running.
        var frames: [XTransImage] = []
        for (i, raw) in raws.enumerated() {
            progress("Decoding \(i + 1) of \(raws.count)")
            frames.append(try XTransDecoder.decode(raw))
            laps.lap("Decoded \(raw.lastPathComponent)")
        }
        let exposures = frames.compactMap(\.exposure)
        guard exposures.count == frames.count else { throw HDRMerger.MergeError.missingExposure }
        let reference = BracketFinder.referenceIndex(exposures)

        progress("Merging")
        let merged = try HDRMerger.merge(frames, reference: reference)
        frames = [] // free the decoded frames before writing
        laps.lap("Merged \(raws.count) frames (reference \(raws[reference].lastPathComponent))")

        progress("Writing DNG and JPEG")
        let camera = previews.indices.contains(reference)
            ? previews[reference].flatMap { ImageLoading.thumbnail(at: $0, maxPixelSize: 512) } : nil
        // Merged values are in units of `scale` × the reference's saturation, so the tone
        // curve's shoulder rolls off the highlights the merge recovered.
        let files = try LinearOutput.write(merged.image, unit: merged.scale, camera: camera,
                                           fallbackBaseline: Double(log2(merged.scale)), metadataFrom: raws[reference],
                                           name: name, into: directory, compression: .none)
        laps.lap("Wrote JPEG and DNG (\(files.report))")
        return Output(dng: files.dng, jpeg: files.jpeg, report: merged.report + laps.lines)
    }
}
