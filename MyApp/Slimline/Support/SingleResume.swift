import Foundation

/// Wraps a continuation so it can only be resumed once.
///
/// `PHImageManager` result handlers can fire more than once — opportunistic delivery sends a
/// low-quality image first — and can also fire with nil on cancellation. Resuming a continuation
/// twice is a hard crash, so this makes every call after the first a no-op.
nonisolated final class SingleResume<Value>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
