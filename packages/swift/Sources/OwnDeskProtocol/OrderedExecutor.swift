import Foundation

/// Runs async operations strictly one after another, in the order they were enqueued.
/// Network and WebRTC callbacks arrive on their own threads; hopping each one into an actor with a
/// separate `Task` would not preserve order, and order matters for `seq` and for key up and down.
public final class OrderedExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    public init() {}

    public func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        lock.unlock()
    }
}
