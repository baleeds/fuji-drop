import Foundation

/// One exposure on the card: the in-camera JPEG and/or the RAF that share a basename
/// (e.g. DSCF1234.JPG + DSCF1234.RAF).
public struct ShotPair<File> {
    public var basename: String
    public var jpeg: File?
    public var raw: File?
    /// Anything else with the same basename (movies, sidecars).
    public var others: [File] = []

    public var isComplete: Bool { jpeg != nil && raw != nil }
}

extension ShotPair: Identifiable {
    public var id: String { basename }
}

public enum ShotPairing {
    static let jpegExtensions: Set<String> = ["JPG", "JPEG"]
    static let rawExtensions: Set<String> = ["RAF"]

    /// Groups files into shots by basename (case-insensitive), sorted by basename.
    public static func pair<File>(_ files: [File], name: (File) -> String) -> [ShotPair<File>] {
        var byKey: [String: ShotPair<File>] = [:]
        for file in files {
            let filename = name(file)
            let ext = (filename as NSString).pathExtension.uppercased()
            let base = (filename as NSString).deletingPathExtension
            let key = base.uppercased()
            var shot = byKey[key] ?? ShotPair(basename: base)
            if jpegExtensions.contains(ext), shot.jpeg == nil {
                shot.jpeg = file
            } else if rawExtensions.contains(ext), shot.raw == nil {
                shot.raw = file
            } else {
                shot.others.append(file)
            }
            byKey[key] = shot
        }
        return byKey.values.sorted { $0.basename.uppercased() < $1.basename.uppercased() }
    }
}
