#if os(iOS)
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
    public static func renderImage(from raw: URL) throws -> CGImage {
        let name = raw.lastPathComponent
        guard let filter = CIRAWFilter(imageURL: raw), let image = filter.outputImage else {
            throw RenderError.cannotDecode(name)
        }
        // sRGB: what Instagram and most sharing targets expect.
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw RenderError.cannotRender(name)
        }
        return cg
    }

    /// Writes `<basename>.JPG` next to `raw` (or into `directory`) and returns its URL.
    /// Uses Apple's default RAW rendering with the RAF's own EXIF (capture date, camera, lens).
    @discardableResult
    /// Pass `image` when the RAF is already decoded at full size (e.g. by compare) to skip
    /// decoding it again; metadata still comes from `raw`.
    public static func renderJPEG(from raw: URL, image: CGImage? = nil, into directory: URL? = nil,
                                  quality: Double = 0.92) throws -> URL {
        let cg = try image ?? renderImage(from: raw)

        var props: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(raw as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] {
                if let value = p[key] { props[key] = value }
            }
        }
        // CIRAWFilter output is already upright.
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props[kCGImageDestinationLossyCompressionQuality] = quality

        let out = (directory ?? raw.deletingLastPathComponent())
            .appendingPathComponent(raw.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("JPG")
        try? FileManager.default.removeItem(at: out)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.cannotWrite(out.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.cannotWrite(out.lastPathComponent) }
        return out
    }
}
#endif
