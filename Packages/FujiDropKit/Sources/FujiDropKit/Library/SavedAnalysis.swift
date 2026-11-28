import Foundation

/// Encodes a shot's analysis (best-shot score with faces, and the Vision feature print used
/// for grouping) for saving next to its preview, so reconnecting doesn't redo it.
///
/// Saved results are thrown away, and recomputed, when:
/// - its version changes: bump `scoreVersion` whenever what `ShotScorer` measures changes
///   (including `FaceBox`), `printVersion` when `FeaturePrinter` changes. Ranking weights and thresholds are applied later, so retuning those
///   doesn't need a bump.
/// - iOS changes: Vision's models (feature prints, aesthetics) can change with it, and prints
///   from different revisions can't be compared.
public enum SavedAnalysis {
    /// 2: face boxes are no longer clipped to the frame.
    public static let scoreVersion = 2
    public static let printVersion = 1

    /// The running system, e.g. "Version 27.2.1 (Build 25C61)".
    public static var system: String { ProcessInfo.processInfo.operatingSystemVersionString }

    struct ScoreFile: Codable {
        var version: Int
        var system: String
        var score: ShotScore
    }

    struct PrintFile: Codable {
        var version: Int
        var system: String
        var revision: Int
        var archive: Data
    }

    public static func encode(_ score: ShotScore, system: String = system) -> Data? {
        try? PropertyListEncoder().encode(ScoreFile(version: scoreVersion, system: system, score: score))
    }

    public static func score(from data: Data, system: String = system) -> ShotScore? {
        guard let file = try? PropertyListDecoder().decode(ScoreFile.self, from: data),
              file.version == scoreVersion, file.system == system else { return nil }
        return file.score
    }

    #if canImport(Vision)
    public static func encode(_ print: FeaturePrint, system: String = system) -> Data? {
        guard let archive = print.archived() else { return nil }
        return try? PropertyListEncoder().encode(
            PrintFile(version: printVersion, system: system, revision: print.revision, archive: archive))
    }

    public static func print(from data: Data, system: String = system) -> FeaturePrint? {
        guard let file = try? PropertyListDecoder().decode(PrintFile.self, from: data),
              file.version == printVersion, file.system == system else { return nil }
        return FeaturePrint(archive: file.archive, revision: file.revision)
    }
    #endif
}
