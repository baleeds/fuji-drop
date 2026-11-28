#if canImport(Vision)
import CoreGraphics
import Vision

/// A Vision feature print: a vector describing an image's content. Smaller distance = more similar.
/// Distances are only comparable between prints of the same request revision.
public struct FeaturePrint: @unchecked Sendable {
    let observation: VNFeaturePrintObservation
    public let revision: Int

    /// The print as data, to save alongside the preview it came from.
    public func archived() -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    /// A print saved with `archived()`.
    public init?(archive: Data, revision: Int) {
        guard let observation = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: archive) else { return nil }
        self.observation = observation
        self.revision = revision
    }

    init(observation: VNFeaturePrintObservation, revision: Int) {
        self.observation = observation
        self.revision = revision
    }

    public func distance(to other: FeaturePrint) -> Float? {
        guard revision == other.revision else { return nil }
        var d: Float = 0
        do {
            try observation.computeDistance(&d, to: other.observation)
            return d
        } catch {
            return nil
        }
    }
}

public enum FeaturePrinter {
    public enum PrintError: Error { case noResult }

    /// Computes a feature print. Pass a small image (~512 px); Vision downsamples anyway.
    /// Must run on a real device: the Simulator returns wrong distances.
    public static func featurePrint(of image: CGImage) throws -> FeaturePrint {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { throw PrintError.noResult }
        return FeaturePrint(observation: observation, revision: request.revision)
    }
}
#endif
