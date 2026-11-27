import Foundation

/// Carries a non-Sendable value across a concurrency boundary: a metadata dictionary across a
/// callback, or a buffer pointer to `DispatchQueue.concurrentPerform` workers that each write a
/// disjoint part of it (rows, strips), which the compiler can't prove on its own.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
