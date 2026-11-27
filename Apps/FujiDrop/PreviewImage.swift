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
        await load(key: "\(url.lastPathComponent)@\(maxPixelSize)" as NSString) {
            await Background.decode {
                ImageLoading.thumbnail(at: url, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
            }
        }
    }

    /// A RAF already decoded at full resolution, without waiting.
    func cachedFullResolution(raw: URL) -> UIImage? {
        cache.object(forKey: Self.fullKey(raw))
    }

    /// Decodes a downloaded RAF at full resolution (about 1.3 s).
    func loadFullResolution(raw: URL) async -> UIImage? {
        await load(key: Self.fullKey(raw)) {
            await Background.raw {
                (try? RAWRenderer.renderImage(from: raw)).map { UIImage(cgImage: $0) }
            }
        }
    }

    private static func fullKey(_ raw: URL) -> NSString { "\(raw.lastPathComponent)@full" as NSString }

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
    @State private var sharp: UIImage?

    var body: some View {
        GeometryReader { geo in
            let pixels = PreviewImageLoader.bucket(Int(max(geo.size.width, geo.size.height) * displayScale))
            ZStack {
                Rectangle().fill(Color(white: 0.12))
                if let image = sharp ?? shot?.thumbnail {
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
            .task(id: LoadKey(url: shot?.previewURL, pixels: pixels)) {
                guard let url = shot?.previewURL, pixels > 360 else { return }
                sharp = await PreviewImageLoader.shared.load(url: url, maxPixelSize: pixels)
            }
        }
    }

    private struct LoadKey: Equatable {
        let url: URL?
        let pixels: Int
    }
}
