import CoreGraphics

/// One face Vision found in a frame.
public struct FaceBox: Equatable, Sendable, Codable {
    /// Normalized to the oriented image, top-left origin. Not clipped to the frame: a face cut
    /// off at an edge reaches past 0…1, so its width is the whole face's (for `countedEyeOpenness`).
    public var rect: CGRect
    /// Eye outline height / width averaged over both eyes (open ≈ 0.3+, closed ≈ 0.1); nil if
    /// Vision found no eye landmarks.
    public var eyeOpenness: Float?

    public init(rect: CGRect, eyeOpenness: Float? = nil) {
        self.rect = rect
        self.eyeOpenness = eyeOpenness
    }

    /// Faces narrower than this fraction of the frame (people in the background) don't count
    /// for closed eyes: their landmarks are too coarse to trust.
    public static let minEyeWidth: CGFloat = 0.06

    /// Eye openness, if the face is big enough for it to count.
    public var countedEyeOpenness: Float? { rect.width >= Self.minEyeWidth ? eyeOpenness : nil }

    /// The one closed-eyes rule, used by ranking (the "Eyes closed" tip) and the face badges.
    public func eyesClosed(below threshold: Float = BestShot.FlawThresholds().eyesClosed) -> Bool {
        countedEyeOpenness.map { $0 < threshold } ?? false
    }
}

/// Follows the same people through the frames of a moment, so their faces can be lined up
/// side by side. Frames of one moment are shot seconds apart with similar framing, so a face
/// is matched by position: the nearest face of similar size, within about one face width.
public enum FaceTracks {
    /// One row per person, left to right in the frame; each row has an entry per frame: that
    /// person's face, or nil where they weren't found (turned away, hidden, or out of frame).
    ///
    /// People are taken from the frame with the most faces, largest first up to `maxPeople`
    /// (background faces matter least). Someone missing from that frame isn't tracked.
    public static func match(_ frames: [[FaceBox]], maxPeople: Int = 4) -> [[FaceBox?]] {
        matchIndices(frames.map { $0.map(\.rect) }, maxPeople: maxPeople)
            .map { row in row.enumerated().map { f, i in i.map { frames[f][$0] } } }
    }

    /// `match` on bare rects: each entry is the index of the face in its frame.
    static func matchIndices(_ frames: [[CGRect]], maxPeople: Int = 4) -> [[Int?]] {
        guard let reference = frames.indices.max(by: { frames[$0].count < frames[$1].count }),
              !frames[reference].isEmpty else { return [] }
        let people = frames[reference]
            .sorted { area($0) > area($1) }
            .prefix(maxPeople)
            .sorted { $0.midX < $1.midX }

        var rows = [[Int?]](repeating: [Int?](repeating: nil, count: frames.count), count: people.count)
        for (f, faces) in frames.enumerated() {
            // Every plausible (person, face) pair, closest first; each person and face used once.
            var pairs: [(person: Int, face: Int, distance: CGFloat)] = []
            for (p, person) in people.enumerated() {
                let width = max(person.width, 0.0001)
                for (j, face) in faces.enumerated() {
                    let ratio = face.width / width
                    guard ratio > 0.5, ratio < 2 else { continue }
                    let d = hypot(face.midX - person.midX, face.midY - person.midY) / width
                    if d < maxDistance { pairs.append((p, j, d)) }
                }
            }
            var usedFaces = Set<Int>()
            for pair in pairs.sorted(by: { $0.distance < $1.distance })
            where rows[pair.person][f] == nil && !usedFaces.contains(pair.face) {
                rows[pair.person][f] = pair.face
                usedFaces.insert(pair.face)
            }
        }
        return rows
    }

    /// How far a face may move between frames, in face widths of the reference face.
    static let maxDistance: CGFloat = 1.0

    private static func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}
