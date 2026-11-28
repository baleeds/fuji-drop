import FujiDropKit
import SwiftUI
import UIKit

/// Decodes cached 1920 px previews at the size they're shown, and downloaded RAFs at full
/// resolution (~64 MB each, for compare), with one in-memory cache.
final class PreviewImageLoader: @unchecked Sendable {
    static let shared = PreviewImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 300_000_000 // bytes of decoded bitmaps
    }

    /// Round requested sizes up to a few buckets so scrolling reuses decoded images.
    static func bucket(_ pixels: Int) -> Int {
        [480, 800, 1200, 1920].first { $0 >= pixels } ?? 1920
    }

    func load(url: URL, maxPixelSize: Int) async -> UIImage? {
        // The full path: merged frames share names across merges (`DSCF2729-HDR.JPG`).
        await load(key: "\(url.path)@\(maxPixelSize)" as NSString) {
            await Background.decode {
                ImageLoading.thumbnail(at: url, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
            }
        }
    }

    /// Square close-ups of faces (`rects`: normalized, top-left origin; nil entries give nil)
    /// from one frame's 1920 px preview, with room for hair and chin. The preview is decoded
    /// once for all its faces and not kept: each close-up is redrawn small and cached alone.
    func faceCrops(url: URL, rects: [CGRect?], pixels: Int) async -> [UIImage?] {
        let keys = rects.map { $0.map { String(format: "%@@face %.4f %.4f %.4f %d", url.path, $0.minX, $0.minY, $0.width, pixels) as NSString } }
        var crops = keys.map { $0.flatMap { cache.object(forKey: $0) } }
        let missing = rects.indices.filter { rects[$0] != nil && crops[$0] == nil }
        guard !missing.isEmpty else { return crops }
        let wanted = missing.compactMap { rects[$0] }
        let decoded = cache.object(forKey: "\(url.path)@1920" as NSString)?.cgImage
        let made = await Background.decode { () -> [UIImage?] in
            guard let preview = decoded ?? ImageLoading.thumbnail(at: url, maxPixelSize: 1920) else {
                return wanted.map { _ in nil }
            }
            return wanted.map { Self.crop(preview, to: $0, pixels: pixels) }
        }
        for (i, image) in zip(missing, made) {
            crops[i] = image
            if let image, let key = keys[i] {
                cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            }
        }
        return crops
    }

    private static func crop(_ image: CGImage, to rect: CGRect, pixels: Int) -> UIImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = max(rect.width * w, rect.height * h) * 1.6
        let crop = CGRect(x: rect.midX * w - side / 2, y: rect.midY * h - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard let cut = image.cropping(to: crop) else { return nil }
        let scale = min(CGFloat(pixels), max(crop.width, crop.height)) / max(crop.width, crop.height)
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard // 8 bits a channel, as the cache's cost assumes
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in UIImage(cgImage: cut).draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// A RAF already decoded at full resolution, without waiting.
    func cachedFullResolution(raw: URL) -> UIImage? {
        cache.object(forKey: Self.fullKey(raw))
    }

    /// Decodes a downloaded RAF at full resolution (about 1.3 s), matching the brightness of
    /// `reference` (the shot's embedded camera JPEG) so DR200/DR400 frames aren't dark.
    func loadFullResolution(raw: URL, reference: URL?) async -> UIImage? {
        await load(key: Self.fullKey(raw)) {
            await Background.raw {
                let ref = reference.flatMap { ImageLoading.thumbnail(at: $0, maxPixelSize: 256) }
                return (try? RAWRenderer.renderImage(from: raw, matching: ref)).map { UIImage(cgImage: $0) }
            }
        }
    }

    /// Keyed by the cache folder too (`DSCF1234-<size>/DSCF1234.RAF`): the file name alone
    /// is shared by a different photo with the same number on another card or camera.
    private static func fullKey(_ raw: URL) -> NSString {
        "\(raw.deletingLastPathComponent().lastPathComponent)/\(raw.lastPathComponent)@full" as NSString
    }

    private func load(key: NSString, decode: () async -> UIImage?) async -> UIImage? {
        if let hit = cache.object(forKey: key) { return hit }
        let image = await decode()
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        }
        return image
    }
}

/// A shot's image filling its frame (cropped). Shows the small thumbnail immediately, then
/// swaps in a sharp decode of the preview sized for the frame.
struct PreviewImage: View {
    let shot: ImportModel.Shot?
    @Environment(\.displayScale) private var displayScale
    /// The sharp decode and which file it is, so a view reused for another shot (a moment's
    /// hero changing) never shows the previous shot's image.
    @State private var sharp: (url: URL, image: UIImage)?

    var body: some View {
        GeometryReader { geo in
            let pixels = PreviewImageLoader.bucket(Int(max(geo.size.width, geo.size.height) * displayScale))
            ZStack {
                Rectangle().fill(Color.tilePlaceholder)
                if let image = (sharp?.url == shot?.previewURL ? sharp?.image : nil) ?? shot?.thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if shot?.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Preview failed")
                }
            }
            .dimmedIfMergeMissing(shot)
            .task(id: LoadKey(url: shot?.previewURL, pixels: pixels)) {
                guard let url = shot?.previewURL, pixels > 360,
                      let image = await PreviewImageLoader.shared.load(url: url, maxPixelSize: pixels)
                else { return }
                sharp = (url, image)
            }
        }
    }

    private struct LoadKey: Equatable {
        let url: URL?
        let pixels: Int
    }
}

extension Color {
    /// Behind a photo tile until its image arrives.
    static let tilePlaceholder = Color(white: 0.12)
}

extension View {
    /// Dims a merged frame whose files were cleared, while it waits for Merge again.
    func dimmedIfMergeMissing(_ shot: ImportModel.Shot?) -> some View {
        opacity(shot?.mergeMissing == true ? 0.4 : 1)
    }
}
