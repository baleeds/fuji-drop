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

    static func decode<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            decodeQueue.async { cont.resume(returning: work()) }
        }
    }

    static func vision<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            visionQueue.async { cont.resume(returning: work()) }
        }
    }

    static func score<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            scoreQueue.async { cont.resume(returning: work()) }
        }
    }
}
