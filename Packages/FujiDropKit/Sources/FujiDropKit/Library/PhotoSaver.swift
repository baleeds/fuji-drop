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
    /// `filename` (e.g. "DSCF1234") names both resources in Photos when the files on disk
    /// have cache names. Returns the new asset's local identifier.
    public static func savePair(
        jpeg: URL,
        raw: URL?,
        filename: String? = nil,
        creationDate: Date? = nil,
        location: CLLocation? = nil,
        rawIsEditingBase: Bool = true
    ) async throws -> String {
        let status = await requestAccess()
        guard status == .authorized || status == .limited else { throw SaveError.notAuthorized(status) }

        final class Box: @unchecked Sendable { var id: String? }
        let box = Box()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let jpegOptions = PHAssetResourceCreationOptions()
            jpegOptions.originalFilename = filename.map { "\($0).\(jpeg.pathExtension)" } ?? jpeg.lastPathComponent
            jpegOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, fileURL: jpeg, options: jpegOptions)

            if let raw {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.originalFilename = filename.map { "\($0).\(raw.pathExtension)" } ?? raw.lastPathComponent
                rawOptions.uniformTypeIdentifier =
                    UTType(filenameExtension: raw.pathExtension)?.identifier ?? "com.fuji.raw-image"
                request.addResource(with: .alternatePhoto, fileURL: raw, options: rawOptions)
            }

            // Make the RAF the unadjusted base, so edits in Photos start from RAW data.
            // Only valid when both resources are present. iOS 27 SDK only: the compiler check
            // keeps the code out of builds with older Xcode (the CI runners lack the iOS 27 SDK).
            #if compiler(>=6.4)
            if raw != nil, rawIsEditingBase, #available(iOS 27, *) {
                request.originalResourceChoice = .raw
            }
            #endif

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

    /// Which resource Photos uses as the editing base for a saved asset, for verification.
    public static func editingBase(forAssetID id: String) -> String {
        #if compiler(>=6.4)
        guard #available(iOS 27, *) else { return "unknown (needs iOS 27)" }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            return "asset not found"
        }
        switch asset.originalResourceChoice {
        case .raw: return "RAW"
        case .compressed: return "JPEG"
        @unknown default: return "other"
        }
        #else
        return "unknown (built without the iOS 27 SDK)"
        #endif
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
