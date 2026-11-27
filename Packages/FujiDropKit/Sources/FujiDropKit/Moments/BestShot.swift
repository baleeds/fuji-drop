import Foundation

/// Raw per-frame measurements used to suggest a moment's best frame.
public struct ShotScore: Equatable, Sendable {
    /// Laplacian focus measure on the subject (see `Sharpness`). Only comparable within a scene.
    public var sharpness: Float
    /// Best face capture quality (0…1: focus, eyes, pose, lighting), nil if no face was found.
    public var faceQuality: Float?
    /// Vision's overall aesthetics score (-1…1), nil if unavailable.
    public var aesthetics: Float?
    /// Eye openness of the least-open face big enough to matter: eye outline height / width,
    /// averaged over both eyes (open ≈ 0.3+, closed ≈ 0.1). Nil if no such face.
    public var eyeOpenness: Float?

    public init(sharpness: Float, faceQuality: Float? = nil, aesthetics: Float? = nil,
                eyeOpenness: Float? = nil) {
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.aesthetics = aesthetics
        self.eyeOpenness = eyeOpenness
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
        /// Total is multiplied by this for each flaw.
        public var flawPenalty: Float = 0.75
        public init() {}
    }

    /// A likely reason a frame isn't the best, shown as a tip.
    public enum Flaw: Sendable {
        case softFocus
        case eyesClosed
        case faceUnclear

        public var title: String {
            switch self {
            case .softFocus: "Soft focus"
            case .eyesClosed: "Eyes closed"
            case .faceUnclear: "Face unclear"
            }
        }
    }

    /// Thresholds for flaws. Starting guesses; calibrate on real shots.
    public struct FlawThresholds: Equatable, Sendable {
        /// Relative sharpness (0…1, 1 = sharpest frame of the moment) below this is soft.
        public var softFocus: Float = 0.7
        /// Eye openness below this counts as closed.
        public var eyesClosed: Float = 0.15
        /// Face quality below this is unclear, if another frame's face reaches `goodFace`.
        public var unclearFace: Float = 0.3
        public var goodFace: Float = 0.5
        public init() {}
    }

    /// Each frame's parts, scaled 0…1, its flaws, and the weighted total.
    public struct Breakdown: Equatable, Sendable {
        public var sharpness: Float
        public var aesthetics: Float?
        public var face: Float?
        public var eyeOpenness: Float?
        public var flaws: [Flaw]
        public var total: Float
    }

    public static func rank(_ scores: [ShotScore], weights: Weights = Weights(),
                            thresholds: FlawThresholds = FlawThresholds()) -> [Breakdown] {
        let maxSharpness = scores.map(\.sharpness).max() ?? 0
        let anyFace = scores.contains { $0.faceQuality != nil }
        let bestFace = scores.compactMap(\.faceQuality).max() ?? 0
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

            var flaws: [Flaw] = []
            // Soft only relative to a sharper frame, so a lone frame is never flagged.
            if scores.count > 1, sharp < thresholds.softFocus { flaws.append(.softFocus) }
            if let eyes = s.eyeOpenness, eyes < thresholds.eyesClosed { flaws.append(.eyesClosed) }
            if let q = s.faceQuality, q < thresholds.unclearFace, bestFace >= thresholds.goodFace {
                flaws.append(.faceUnclear)
            }

            var result = weight > 0 ? total / weight : 0
            for _ in flaws { result *= weights.flawPenalty }
            return Breakdown(sharpness: sharp, aesthetics: aesthetics, face: face,
                             eyeOpenness: s.eyeOpenness, flaws: flaws, total: result)
        }
    }

    /// Index of the suggested frame; ties go to the earlier frame.
    public static func bestIndex(_ scores: [ShotScore]) -> Int? {
        bestIndex(rank(scores))
    }

    /// Index of the highest total in already-ranked frames; ties go to the earlier frame.
    public static func bestIndex(_ ranked: [Breakdown]) -> Int? {
        guard var best = ranked.indices.first else { return nil }
        for i in ranked.indices.dropFirst() where ranked[i].total > ranked[best].total { best = i }
        return best
    }
}
