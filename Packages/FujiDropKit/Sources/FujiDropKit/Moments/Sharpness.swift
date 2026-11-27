import CoreGraphics

/// An 8-bit grayscale bitmap, row 0 at the top.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws `image` into a grayscale bitmap at its own size, or scaled down so its longer
    /// side is at most `maxSide`.
    public init?(_ image: CGImage, maxSide: Int? = nil) {
        let scale = maxSide.map { min(1, Double($0) / Double(max(image.width, image.height, 1))) } ?? 1
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = scale < 1 ? .medium : .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        self.init(width: w, height: h, pixels: pixels)
    }
}

/// Focus measure: variance of the Laplacian (edge response) in small tiles.
///
/// Only meaningful relative to other frames of the same scene: absolute values depend on
/// texture, noise (ISO) and JPEG compression. Scoring the sharpest quarter of tiles in the
/// subject region keeps soft backgrounds and empty sky from diluting the in-focus part.
public enum Sharpness {
    /// - Parameters:
    ///   - region: normalized rectangle (0…1, origin top-left) to measure, e.g. the faces or
    ///     the salient subject. Defaults to the whole image.
    ///   - tile: tile side in pixels.
    public static func score(_ image: GrayImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                             tile: Int = 64) -> Float {
        let w = image.width, h = image.height
        guard w >= 3, h >= 3 else { return 0 }
        // Pixel bounds, keeping a 1-pixel border for the 3×3 kernel.
        let x0 = clamp(Int((region.minX * CGFloat(w)).rounded(.down)), 1, w - 2)
        let x1 = clamp(Int((region.maxX * CGFloat(w)).rounded(.up)), x0 + 1, w - 1)
        let y0 = clamp(Int((region.minY * CGFloat(h)).rounded(.down)), 1, h - 2)
        let y1 = clamp(Int((region.maxY * CGFloat(h)).rounded(.up)), y0 + 1, h - 1)

        return image.pixels.withUnsafeBufferPointer { p -> Float in
            func variance(_ tx0: Int, _ ty0: Int, _ tx1: Int, _ ty1: Int) -> Float {
                var sum: Double = 0, sumSquares: Double = 0
                for y in ty0..<ty1 {
                    let row = y * w
                    for x in tx0..<tx1 {
                        let i = row + x
                        let l = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1]) - Int(p[i - w]) - Int(p[i + w])
                        sum += Double(l)
                        sumSquares += Double(l * l)
                    }
                }
                let n = Double((tx1 - tx0) * (ty1 - ty0))
                guard n > 0 else { return 0 }
                let mean = sum / n
                return Float(max(0, sumSquares / n - mean * mean))
            }

            var tiles: [Float] = []
            var ty = y0
            while ty + tile <= y1 {
                var tx = x0
                while tx + tile <= x1 {
                    tiles.append(variance(tx, ty, tx + tile, ty + tile))
                    tx += tile
                }
                ty += tile
            }
            // Region smaller than one tile: measure it whole.
            guard !tiles.isEmpty else { return variance(x0, y0, x1, y1) }
            tiles.sort(by: >)
            let top = tiles.prefix(max(1, tiles.count / 4))
            return top.reduce(0, +) / Float(top.count)
        }
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), max(lo, hi)) }
}
