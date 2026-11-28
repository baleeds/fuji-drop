#if canImport(Vision)
import CoreGraphics
import Vision

/// Measures one frame for best-shot ranking. Pass the oriented 1920 px preview: sharpness needs
/// the full preview resolution (downscaling hides missed focus).
public enum ShotScorer {
    public enum ScoreError: Error { case noBitmap }

    /// Faces, subject region and focus. Synchronous and CPU/ANE heavy: run it off the
    /// cooperative thread pool.
    public static func measure(_ image: CGImage) throws -> ShotScore {
        let faces = VNDetectFaceCaptureQualityRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, saliency, landmarks])

        let faceObservations = faces.results ?? []
        let quality = faceObservations.compactMap(\.faceCaptureQuality).max()

        // Where to measure focus: faces (with some margin for hair and eyes at the edge of the
        // box), else the salient subject, else the middle of the frame.
        let region: CGRect
        if let box = union(faceObservations.map(\.boundingBox)) {
            region = box.insetBy(dx: -box.width * 0.25, dy: -box.height * 0.25)
        } else if let box = union(saliency.results?.first?.salientObjects?.map(\.boundingBox) ?? []) {
            region = box
        } else {
            region = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        }
        let focus = topLeft(region).intersection(unit)

        let size = CGSize(width: image.width, height: image.height)
        let faceBoxes: [FaceBox] = (landmarks.results ?? [])
            .filter { $0.boundingBox.width >= minCloseUpWidth }
            .map { FaceBox(rect: topLeft($0.boundingBox), eyeOpenness: eyeOpenness($0, imageSize: size)) } // unclipped

        guard let gray = GrayImage(image) else { throw ScoreError.noBitmap }
        return ShotScore(sharpness: Sharpness.score(gray, region: focus.isNull ? unit : focus),
                         faceQuality: quality, faces: faceBoxes)
    }

    /// Faces narrower than this fraction of the frame (under ~75 px in the 1920 px preview)
    /// aren't worth a close-up.
    static let minCloseUpWidth: CGFloat = 0.04

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// A Vision rect (bottom-left origin) in the bitmap's top-left coordinates.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Mean of both eyes' outline height / width, in image pixels.
    static func eyeOpenness(_ face: VNFaceObservation, imageSize: CGSize) -> Float? {
        func ratio(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
            guard let points = region?.pointsInImage(imageSize: imageSize), points.count >= 4,
                  let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
                  maxX - minX > 1 else { return nil }
            return (maxY - minY) / (maxX - minX)
        }
        let ratios = [ratio(face.landmarks?.leftEye), ratio(face.landmarks?.rightEye)].compactMap { $0 }
        guard !ratios.isEmpty else { return nil }
        return Float(ratios.reduce(0, +) / CGFloat(ratios.count))
    }

    /// Vision's overall aesthetics score (-1…1), or nil where it isn't supported.
    public static func aesthetics(of image: CGImage) async -> Float? {
        let request = CalculateImageAestheticsScoresRequest()
        return try? await request.perform(on: image).overallScore
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for r in rects.dropFirst() { result = result.union(r) }
        return result
    }
}
#endif
