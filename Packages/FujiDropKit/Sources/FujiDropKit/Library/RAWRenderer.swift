import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a full-resolution JPEG from a RAF with Apple's RAW pipeline, so a RAW-only shot
/// can be saved to Photos as a RAW+JPEG pair (the JPEG is what sharing apps receive).
public enum RAWRenderer {
    public enum RenderError: LocalizedError {
        case cannotDecode(String)
        case cannotRender(String)
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .cannotDecode(let f): return "Core Image could not decode \(f)"
            case .cannotRender(let f): return "Could not render \(f)"
            case .cannotWrite(let f): return "Could not write JPEG \(f)"
            }
        }
    }

    /// Shared context; creating one per image is expensive.
    nonisolated(unsafe) static let context = CIContext(options: [.cacheIntermediates: false])

    /// Decodes a RAF at full resolution (upright, sRGB) with Apple's default RAW rendering.
    /// About 1.3 s and ~64 MB per X-T1 frame: call it off the main thread.
    ///
    /// Pass the camera's own JPEG (e.g. the embedded preview, any size) as `reference` to
    /// match its overall brightness: Fuji underexposes the RAW for DR200/DR400 and only the
    /// in-camera JPEG is lifted, so a plain render looks 1–2 stops dark.
    public static func renderImage(from raw: URL, matching reference: CGImage? = nil) throws -> CGImage {
        let name = raw.lastPathComponent
        guard let filter = CIRAWFilter(imageURL: raw) else { throw RenderError.cannotDecode(name) }
        if let reference { matchExposure(filter, to: reference) }
        guard let image = filter.outputImage else { throw RenderError.cannotDecode(name) }
        // sRGB: what Instagram and most sharing targets expect.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw RenderError.cannotRender(name)
        }
        return cg
    }

    /// Sets `filter.exposure` so a small render's overall brightness matches `reference`, and
    /// returns it. Several passes, since the tone curve makes each estimate approximate; the
    /// result is clamped to `range` against a wild estimate (e.g. a reference that isn't this
    /// frame). A few milliseconds; leaves the filter at full size for the real render.
    /// `draft` speeds up RAF demosaicing; leave it off for our own DNGs.
    @discardableResult
    static func matchExposure(_ filter: CIRAWFilter, to reference: CGImage, passes: Int = 2,
                              range: ClosedRange<Float> = -2...4, draft: Bool = true) -> Float {
        guard let target = GrayImage(reference, maxSide: 256) else { return filter.exposure }
        let fullScale = filter.scaleFactor
        filter.isDraftModeEnabled = draft
        filter.scaleFactor = Float(256 / max(filter.nativeSize.width, filter.nativeSize.height, 1))
        defer {
            filter.isDraftModeEnabled = false
            filter.scaleFactor = fullScale
        }
        var ev: Float = 0
        for _ in 0..<passes {
            filter.exposure = ev
            guard let small = filter.outputImage,
                  let cg = context.createCGImage(small, from: small.extent),
                  let probe = GrayImage(cg, maxSide: 256) else { break }
            ev += Brightness.stops(toMatch: target, from: probe)
        }
        filter.exposure = min(max(ev, range.lowerBound), range.upperBound)
        return filter.exposure
    }

    /// Writes `<basename>.JPG` next to `raw` (or into `directory`) and returns its URL.
    /// Uses Apple's default RAW rendering with the RAF's own EXIF (capture date, camera, lens).
    /// Pass `image` when the RAF is already decoded at full size (e.g. by compare) to skip
    /// decoding it again; metadata still comes from `raw`. Otherwise `reference` (the
    /// camera's JPEG) sets the brightness as in `renderImage`.
    @discardableResult
    public static func renderJPEG(from raw: URL, image: CGImage? = nil, matching reference: CGImage? = nil,
                                  into directory: URL? = nil, quality: Double = 0.92) throws -> URL {
        let cg = try image ?? renderImage(from: raw, matching: reference)
        let out = (directory ?? raw.deletingLastPathComponent())
            .appendingPathComponent(raw.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("JPG")
        try writeJPEG(cg, metadataFrom: raw, to: out, quality: quality)
        return out
    }

    /// Writes an upright image as a JPEG with `source`'s EXIF, TIFF and GPS metadata (capture
    /// date, camera, lens), orientation reset to 1.
    public static func writeJPEG(_ cg: CGImage, metadataFrom source: URL, to out: URL, quality: Double = 0.92) throws {
        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
                if let value = p[key] { props[key] = value }
            }
        }
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImageDestinationLossyCompressionQuality] = quality
        try? FileManager.default.removeItem(at: out)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.cannotWrite(out.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.cannotWrite(out.lastPathComponent) }
    }
}
