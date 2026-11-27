import Foundation

/// Overall brightness of an image, for matching a RAW render to the camera's own JPEG.
///
/// Fuji bodies underexpose the RAW on purpose when dynamic range is set to DR200/DR400 (1–2
/// stops) and lift the in-camera JPEG to compensate; a generic RAW decoder doesn't know to
/// lift, so its render comes out dark. Comparing the two images' log-average luminance gives
/// the exposure offset (in stops) that brings the render back to the camera's look.
public enum Brightness {
    /// sRGB-encoded 8-bit value → linear light (0…1).
    private static let linear: [Float] = (0...255).map { v in
        let c = Float(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Mean of log2(linear luminance) over the image: one number per image whose difference
    /// between two images is an exposure difference in stops. Near-black pixels are floored so
    /// deep shadows (and sensor noise) don't dominate.
    public static func logAverage(_ image: GrayImage) -> Float {
        guard !image.pixels.isEmpty else { return 0 }
        var log = [Float](repeating: 0, count: 256)
        for v in 0..<256 { log[v] = log2(max(linear[v], 1.0 / 1024)) }
        var sum: Float = 0
        for p in image.pixels { sum += log[Int(p)] }
        return sum / Float(image.pixels.count)
    }

    /// Stops to add to `image` so its overall brightness matches `reference`.
    public static func stops(toMatch reference: GrayImage, from image: GrayImage) -> Float {
        logAverage(reference) - logAverage(image)
    }
}
