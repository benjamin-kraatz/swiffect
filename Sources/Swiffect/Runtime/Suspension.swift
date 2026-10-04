import Synchronization

/// A one-shot rendezvous between a suspended fiber and whoever completes it.
///
/// The first call to ``complete(_:)`` wins; later calls are ignored. `nil` signals that the
/// waiting fiber was interrupted.
final class Suspension<T: Sendable>: Sendable {
    private enum State {
        case pending
        case waiting(UnsafeContinuation<T?, Never>)
        case done(T?)
    }

    private let state = Mutex<State>(.pending)

    /// Delivers the outcome. Returns `false` if an outcome was already delivered.
    @discardableResult
    func complete(_ value: T?) -> Bool {
        let (accepted, continuation): (Bool, UnsafeContinuation<T?, Never>?) = state.withLock { state in
            switch state {
            case .pending:
                state = .done(value)
                return (true, nil)
            case .waiting(let continuation):
                state = .done(value)
                return (true, continuation)
            case .done:
                return (false, nil)
            }
        }
        continuation?.resume(returning: value)
        return accepted
    }

    /// Waits for the outcome. Must be called at most once.
    func wait() async -> T? {
        await withUnsafeContinuation { continuation in
            let ready: T?? = state.withLock { state in
                switch state {
                case .pending:
                    state = .waiting(continuation)
                    return .none
                case .done(let value):
                    return .some(value)
                case .waiting:
                    preconditionFailure("Suspension awaited twice")
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
