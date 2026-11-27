import Foundation

/// Groups shots into "moments": time first, then visual similarity.
///
/// Rule (from the research doc): frames a few seconds apart are one moment unless they look
/// very different; frames further apart join only if they look very similar. Distances are
/// Vision feature-print distances (smaller = more similar). They have no fixed scale, so the
/// defaults are starting guesses for the current print revision (normalized vectors, roughly
/// 0 = identical to ~1.4 = unrelated) and must be calibrated on real X-T1 shots.
public struct MomentGrouper: Equatable, Sendable {
    /// Consecutive frames within this gap are the same moment by default.
    public var burstGap: TimeInterval = 3
    /// Within `burstGap`, split if the distance is above this.
    public var splitDistance: Float = 0.6
    /// Frames up to this far apart may still join if they are very similar.
    public var joinGap: TimeInterval = 180
    /// Beyond `burstGap` (and within `joinGap`), join only if distance is below this.
    public var joinDistance: Float = 0.3

    public init() {}

    /// - Parameters:
    ///   - items: shots in any order; they are stably sorted by `date`.
    ///   - distance: visual distance between two shots, or nil if unknown (time-only).
    public func group<T>(
        _ items: [T],
        date: (T) -> Date,
        distance: ((T, T) -> Float?)? = nil
    ) -> [[T]] {
        // Stable: frames with equal timestamps (common in bursts) keep the caller's order.
        let sorted = items.enumerated()
            .sorted { (date($0.element), $0.offset) < (date($1.element), $1.offset) }
            .map(\.element)
        var moments: [[T]] = []
        for item in sorted {
            guard let previous = moments.last?.last else {
                moments.append([item])
                continue
            }
            let gap = date(item).timeIntervalSince(date(previous))
            let d = distance?(previous, item)
            if belongTogether(gap: gap, distance: d) {
                moments[moments.count - 1].append(item)
            } else {
                moments.append([item])
            }
        }
        return moments
    }

    func belongTogether(gap: TimeInterval, distance: Float?) -> Bool {
        if gap <= burstGap {
            guard let distance else { return true }
            return distance <= splitDistance
        }
        if gap <= joinGap, let distance {
            return distance <= joinDistance
        }
        return false
    }
}
