import Foundation

/// What Fuji Drop knows about a Fujifilm body from its model name (as iOS or the RAF reports
/// it, e.g. "X-T1" or "FUJIFILM X-T5"): which sensor it has, and whether it's one of the 40 MP
/// bodies whose decodes are 2.5× the X-T1's size.
///
/// Browsing, compare and saving the RAF work on any Fuji (Apple decodes those). The LibRaw
/// paths (Save RAW as DNG, HDR merge) are tuned for X-Trans, so they're offered only when the
/// sensor isn't known to be Bayer. An unrecognised name counts as X-Trans, since nearly every
/// current X body is; `XTransDecoder` checks the actual file and refuses anything else.
public struct FujiCamera: Equatable, Sendable {
    public enum Sensor: Equatable, Sendable {
        case xTrans
        case bayer
        case unknown
    }

    /// The model as Fujifilm names it ("X-T1"), without the maker; empty if unknown.
    public var model: String
    public var sensor: Sensor
    /// A 40 MP body: an X-T1 frame decodes to ~96 MB, these to ~240 MB, so a 3-frame HDR merge
    /// may run the phone out of memory.
    public var isHighResolution: Bool

    public init(name: String?) {
        model = Self.modelName(name ?? "")
        sensor = Self.sensor(of: model)
        isHighResolution = Self.highResolution.contains(model)
    }

    /// DNG saves and HDR merges (LibRaw with X-Trans demosaicing and colour cleanup).
    public var supportsXTransProcessing: Bool { sensor != .bayer }

    /// "FUJIFILM X-T1" → "X-T1"; "GFX 50S II" stays whole.
    static func modelName(_ name: String) -> String {
        var s = name.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for maker in ["FUJIFILM", "FUJI"] where s.hasPrefix(maker) {
            s = String(s.dropFirst(maker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if s.hasPrefix("GFX") { return s }
        return s.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Fujifilm's Bayer-sensor bodies; every other X body (from the X-Pro1 on) is X-Trans.
    static func sensor(of model: String) -> Sensor {
        guard !model.isEmpty else { return .unknown }
        if model.hasPrefix("GFX") || model.hasPrefix("X-A") || bayerModels.contains(model) { return .bayer }
        return model.hasPrefix("X") ? .xTrans : .unknown
    }

    static let bayerModels: Set<String> = ["X-T100", "X-T200", "X100", "X-S1", "X10", "XF1", "XF10"]

    static let highResolution: Set<String> = ["X-T5", "X-T50", "X-H2", "X100VI", "X-E5"]
}
