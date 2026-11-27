import Foundation
import ImageIO

/// A frame's exposure settings, from EXIF.
public struct Exposure: Equatable, Sendable {
    /// Seconds.
    public var time: Double
    public var fNumber: Double
    public var iso: Double
    /// Exposure compensation in stops (ExposureBiasValue): what the photographer asked for.
    public var bias: Double
    public var date: Date?

    public init(time: Double, fNumber: Double, iso: Double, bias: Double, date: Date? = nil) {
        self.time = time
        self.fNumber = fNumber
        self.iso = iso
        self.bias = bias
        self.date = date
    }

    /// Reads ExposureTime, FNumber, ISO, ExposureBiasValue and DateTimeOriginal from ImageIO
    /// properties (a RAF, or the embedded preview JPEG, which keeps the camera's EXIF).
    public init?(properties: [String: Any]) {
        guard let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let t = Self.number(exif[kCGImagePropertyExifExposureTime as String]), t > 0,
              let n = Self.number(exif[kCGImagePropertyExifFNumber as String]), n > 0,
              let iso = Self.number((exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first), iso > 0
        else { return nil }
        self.init(time: t, fNumber: n, iso: iso,
                  bias: Self.number(exif[kCGImagePropertyExifExposureBiasValue as String]) ?? 0,
                  date: (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(Self.parse))
    }

    /// Reads the EXIF of an image file without decoding it (a few milliseconds).
    public init?(contentsOf url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        self.init(properties: p)
    }

    /// Exposure value at ISO 100: log2(N²/t) − log2(ISO/100). One stop more light = 1 less.
    public var ev: Double { log2(fNumber * fNumber / time) - log2(iso / 100) }

    /// Light captured relative to `other`, in stops (+1 = twice the exposure).
    public func stops(relativeTo other: Exposure) -> Double { other.ev - ev }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    private static func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

/// Finds exposure brackets: runs of frames of one scene, shot seconds apart, each at a
/// different exposure on purpose.
///
/// "On purpose" is what separates a bracket from a burst whose auto exposure drifted (auto
/// ISO and shutter change by a stop as the light or framing shifts). So every frame must
/// differ from every other in both the exposure compensation the camera recorded
/// (ExposureBiasValue: AE BKT records each frame's offset, and a manual bracket is shot with
/// the compensation dial) and the exposure actually captured. A bracket shot in full manual
/// by changing the shutter speed has no compensation change and isn't found.
public struct BracketFinder: Equatable, Sendable {
    /// Consecutive frames at most this far apart (AE BKT fires within a second; a manual
    /// bracket needs a few seconds to turn the dial).
    public var maxGap: TimeInterval = 5
    /// Minimum difference in exposure compensation between any two frames (⅔ stop, less
    /// rounding: EXIF stores −0.67).
    public var minBiasStep: Double = 0.6
    /// Minimum difference in captured exposure between any two frames. Looser than the bias
    /// step: auto ISO doesn't always follow the compensation exactly.
    public var minExposureStep: Double = 0.5
    public var minFrames = 3
    /// Consecutive frames must look like one scene (feature-print distance), when known.
    public var maxDistance: Float = 0.6

    public init() {}

    /// - Parameters:
    ///   - items: frames in time order.
    ///   - distance: visual distance between two frames, or nil if unknown.
    /// - Returns: the index ranges of brackets in `items`, in order, not overlapping.
    public func find<T>(
        _ items: [T],
        date: (T) -> Date?,
        exposure: (T) -> Exposure?,
        distance: ((T, T) -> Float?)? = nil
    ) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var start = 0 // window is start..<i
        func close(at end: Int) {
            if end - start >= minFrames { found.append(start..<end) }
        }
        for i in items.indices {
            guard let e = exposure(items[i]) else {
                close(at: i)
                start = i + 1
                continue
            }
            if i > start {
                let previous = items[i - 1]
                let gapOK: Bool = {
                    guard let a = date(previous), let b = date(items[i]) else { return false }
                    return abs(b.timeIntervalSince(a)) <= maxGap
                }()
                let sceneOK = distance?(previous, items[i]).map { $0 <= maxDistance } ?? true
                if !gapOK || !sceneOK {
                    close(at: i)
                    start = i
                    continue
                }
                // The latest frame in the window this one repeats (same exposure on purpose).
                let clash = (start..<i).last { j in
                    guard let o = exposure(items[j]) else { return true }
                    return abs(o.bias - e.bias) < minBiasStep || abs(o.ev - e.ev) < minExposureStep
                }
                if let clash {
                    if i - start >= minFrames {
                        // A complete bracket followed by another (or by a normal frame).
                        close(at: i)
                        start = i
                    } else {
                        // Not a bracket yet: drop the frames up to the repeat and carry on.
                        start = clash + 1
                    }
                }
            }
        }
        close(at: items.count)
        return found
    }

    /// The frame the others are aligned to and normalized against: the middle exposure.
    public static func referenceIndex(_ exposures: [Exposure]) -> Int {
        let byEV = exposures.indices.sorted { exposures[$0].ev < exposures[$1].ev }
        return byEV[byEV.count / 2]
    }

    /// Merges moments so no bracket is split between them (the frames of a bracket can look
    /// different enough, being stops apart, for grouping to cut it). Moments and brackets are
    /// both runs of the same time order.
    public static func keepTogether<ID: Hashable>(_ moments: [[ID]], brackets: [[ID]]) -> [[ID]] {
        var momentOf: [ID: Int] = [:]
        for (m, ids) in moments.enumerated() { for id in ids { momentOf[id] = m } }
        // Union of moments spanned by each bracket: since both are runs of one order, merging
        // the first through the last moment a bracket touches is enough.
        var joinNext = [Bool](repeating: false, count: moments.count)
        for b in brackets {
            let ms = b.compactMap { momentOf[$0] }
            guard let lo = ms.min(), let hi = ms.max(), lo < hi else { continue }
            for m in lo..<hi { joinNext[m] = true }
        }
        var out: [[ID]] = []
        var current: [ID] = []
        for (m, ids) in moments.enumerated() {
            current += ids
            if !joinNext[m] {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
