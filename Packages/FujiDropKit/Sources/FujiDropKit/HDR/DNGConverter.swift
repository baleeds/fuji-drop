import Foundation

/// Converts one RAF to a linear DNG and a JPEG from the same decode (docs/HDR-PLAN.md, step 3,
/// "Save RAW as DNG"): LibRaw's Markesteijn demosaic plus the false-colour cleanup, written as
/// 16-bit integer LinearRaw with lossless JPEG compression, and a JPEG rendered with
/// `LinearRenderer` instead of Apple's RAW filter. Blocking and heavy: run it on a background
/// queue.
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
    public static func convert(raw: URL, preview: URL?, name: String, into directory: URL) throws -> Output {
        var laps = Laps()
        var frame = try XTransDecoder.decode(raw)
        laps.lap("Decoded")
        let native = ColorCleanup.clean(frame)
        frame.pixels = [] // done with the white-balanced copy
        laps.lap("Cleaned colour")

        let image = LinearImage(width: frame.width, height: frame.height, samples: .integer(native),
                                crop: (0, 0, frame.width, frame.height), wb: frame.wb, camXYZ: frame.camXYZ,
                                make: frame.make, model: frame.model, properties: frame.properties)
        let files = try LinearOutput.write(image, unit: 1 / 65535,
                                           camera: preview.flatMap { ImageLoading.thumbnail(at: $0, maxPixelSize: 512) },
                                           metadataFrom: raw, name: name, into: directory, compression: .losslessJPEG)
        laps.lap("Wrote JPEG and DNG (\(files.report))")
        return Output(dng: files.dng, jpeg: files.jpeg, report: laps.lines)
    }
}
