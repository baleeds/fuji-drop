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
        // Vision's origin is bottom-left; the bitmap's is top-left.
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let topLeft = CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height)
            .intersection(unit)

        let size = CGSize(width: image.width, height: image.height)
        let eyes = (landmarks.results ?? [])
            .filter { $0.boundingBox.width >= minFaceWidth }
            .compactMap { eyeOpenness($0, imageSize: size) }
            .min()

        guard let gray = GrayImage(image) else { throw ScoreError.noBitmap }
        return ShotScore(sharpness: Sharpness.score(gray, region: topLeft.isNull ? unit : topLeft),
                         faceQuality: quality, eyeOpenness: eyes)
    }

    /// Faces narrower than this fraction of the frame (people in the background) don't count
    /// for closed eyes: their landmarks are too coarse.
    static let minFaceWidth: CGFloat = 0.06

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
