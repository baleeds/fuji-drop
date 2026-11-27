#if os(iOS)
import CoreLocation
import Foundation
import Photos
import UniformTypeIdentifiers

/// Saves a shot to Apple Photos as one RAW+JPEG asset: JPEG as `.photo`, RAF as
/// `.alternatePhoto` (the shape Photos uses for external-camera imports).
public enum PhotoSaver {
    public struct SavedResource: Sendable, CustomStringConvertible {
        public var type: PHAssetResourceType
        public var filename: String
        public var uti: String

        public var description: String { "\(PhotoSaver.name(of: type)): \(filename) [\(uti)]" }
    }

    public enum SaveError: LocalizedError {
        case notAuthorized(PHAuthorizationStatus)
        case noPlaceholder
        public var errorDescription: String? {
            switch self {
            case .notAuthorized(let s): return "Photos access not granted (status \(s.rawValue))"
            case .noPlaceholder: return "Photos did not return a new asset identifier"
            }
        }
    }

    /// Read/write access is needed so we can fetch the asset back and verify its resources.
    public static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Saves the pair. RAW must be a file URL (in-memory data is unreliable for pairing).
    /// Returns the new asset's local identifier.
    public static func savePair(
        jpeg: URL,
        raw: URL?,
        creationDate: Date? = nil,
        location: CLLocation? = nil
    ) async throws -> String {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized(status) }

        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let jpegOptions = PHAssetResourceCreationOptions()
            jpegOptions.originalFilename = jpeg.lastPathComponent
            jpegOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, fileURL: jpeg, options: jpegOptions)

            if let raw {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = raw.lastPathComponent
                rawOptions.uniformTypeIdentifier =
                    UTType(filenameExtension: raw.pathExtension)?.identifier ?? "com.fuji.raw-image"
                request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
            }

            // TODO(iOS 27): set `originalResourceChoice` so the RAF is the unadjusted base for edits.
            // Check the exact API in the iOS 27 SDK before enabling.

            if let creationDate { request.creationDate = creationDate }
            if let location { request.location = location }
            box.id = request.placeholderForCreatedAsset?.localIdentifier
        }

        guard let id = box.id else { throw SaveError.noPlaceholder }
        return id
    }

    /// Lists the resources Photos actually stored for an asset, to verify pairing.
    public static func resources(forAssetID id: String) -> [SavedResource] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return []
        }
        return PHAssetResource.assetResources(for: asset).map {
            SavedResource(type: $0.type, filename: $0.originalFilename, uti: $0.uniformTypeIdentifier)
        }
    }

    public static func name(of type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "photo"
        case .alternatePhoto: return "alternatePhoto"
        case .fullSizePhoto: return "fullSizePhoto"
        case .adjustmentData: return "adjustmentData"
        case .adjustmentBasePhoto: return "adjustmentBasePhoto"
        default: return "type \(type.rawValue)"
        }
    }
}
#endif
