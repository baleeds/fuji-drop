import Foundation

/// Runs blocking work (ImageIO decodes, Vision requests) on dedicated GCD queues rather than
/// Swift's cooperative thread pool. That pool has only a few threads; filling it with
/// synchronous work stalls every other task in the app.
enum Background {
    private static let decodeQueue = DispatchQueue(
        label: "FujiDrop.decode", qos: .userInitiated, attributes: .concurrent)
    /// Vision runs one request at a time.
    private static let visionQueue = DispatchQueue(label: "FujiDrop.vision", qos: .utility)
    /// Best-shot scoring: lowest priority, so it never holds up feature prints (grouping).
    private static let scoreQueue = DispatchQueue(label: "FujiDrop.score", qos: .background)
    /// Full-resolution RAW decodes: one at a time (each needs a few hundred MB while it runs).
    private static let rawQueue = DispatchQueue(label: "FujiDrop.raw", qos: .userInitiated)

    static func decode<T>(_ work: @escaping @Sendable () -> T) async -> T { await run(on: decodeQueue, work) }
    static func vision<T>(_ work: @escaping @Sendable () -> T) async -> T { await run(on: visionQueue, work) }
    static func score<T>(_ work: @escaping @Sendable () -> T) async -> T { await run(on: scoreQueue, work) }
    static func raw<T>(_ work: @escaping @Sendable () -> T) async -> T { await run(on: rawQueue, work) }

    private static func run<T>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: work()) }
        }
    }
}

extension FileManager {
    /// Hard-links `source` to `destination` (instant, no extra space), or copies it if linking
    /// isn't possible (another volume).
    func linkOrCopy(_ source: URL, to destination: URL) throws {
        do {
            try linkItem(at: source, to: destination)
        } catch {
            try copyItem(at: source, to: destination)
        }
    }
}
