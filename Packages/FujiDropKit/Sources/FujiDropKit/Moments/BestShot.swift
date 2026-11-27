import Foundation

/// Raw per-frame measurements used to suggest a moment's best frame.
public struct ShotScore: Equatable, Sendable {
    /// Laplacian focus measure on the subject (see `Sharpness`). Only comparable within a scene.
    public var sharpness: Float
    /// Best face capture quality (0…1: focus, eyes, pose, lighting), nil if no face was found.
    public var faceQuality: Float?
    /// Vision's overall aesthetics score (-1…1), nil if unavailable.
    public var aesthetics: Float?

    public init(sharpness: Float, faceQuality: Float? = nil, aesthetics: Float? = nil) {
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.aesthetics = aesthetics
    }
}

/// Ranks the frames of one moment. Scores are relative to the other frames, because the
/// sharpness measure has no absolute scale.
public enum BestShot {
    public struct Weights: Equatable, Sendable {
        public var sharpness: Float = 0.55
        public var aesthetics: Float = 0.25
        /// Only applied when at least one frame of the moment has a face.
        public var face: Float = 0.20
        public init() {}
    }

    /// Each frame's parts, scaled 0…1, and the weighted total.
    public struct Breakdown: Equatable, Sendable {
        public var sharpness: Float
        public var aesthetics: Float?
        public var face: Float?
        public var total: Float
    }

    public static func rank(_ scores: [ShotScore], weights: Weights = Weights()) -> [Breakdown] {
        let maxSharpness = scores.map(\.sharpness).max() ?? 0
        let anyFace = scores.contains { $0.faceQuality != nil }
        let anyAesthetics = scores.contains { $0.aesthetics != nil }
        return scores.map { s in
            // Laplacian variance grows with the square of edge contrast; the root is closer to
            // how much sharper a frame looks.
            let sharp = maxSharpness > 0 ? (max(0, s.sharpness) / maxSharpness).squareRoot() : 0
            var total = weights.sharpness * sharp
            var weight = weights.sharpness
            let aesthetics = s.aesthetics.map { min(max(($0 + 1) / 2, 0), 1) }
            if anyAesthetics {
                total += weights.aesthetics * (aesthetics ?? 0.5)
                weight += weights.aesthetics
            }
            // In a moment with faces, a frame where no face was detected (turned away, blurred
            // beyond recognition) scores zero here.
            let face = anyFace ? (s.faceQuality ?? 0) : nil
            if let face {
                total += weights.face * face
                weight += weights.face
            }
            return Breakdown(sharpness: sharp, aesthetics: aesthetics, face: face,
                             total: weight > 0 ? total / weight : 0)
        }
    }

    /// Index of the suggested frame; ties go to the earlier frame.
    public static func bestIndex(_ scores: [ShotScore], weights: Weights = Weights()) -> Int? {
        let ranked = rank(scores, weights: weights)
        guard var best = ranked.indices.first else { return nil }
        for i in ranked.indices.dropFirst() where ranked[i].total > ranked[best].total { best = i }
        return best
    }
}
