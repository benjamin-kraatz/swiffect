import Synchronization

/// Supervises fibers forked by a single operator (forEach, race, ...) on behalf of a parent
/// fiber and delivers their exits in completion order.
///
/// The children are not registered as children of the parent fiber: the operator owns them
/// and must interrupt and await them before it returns (``interruptAll()`` +
/// ``awaitAll()``).
final class ChildGroup<A: Sendable, E: Error>: Sendable {
    private struct State {
        var events: [(index: Int, exit: Exit<A, E>)] = []
        var waiter: (@Sendable () -> Void)?
        var running: [Int: Fiber<A, E>] = [:]
    }

    private let state = Mutex(State())
    private let parent: FiberRuntime
    private let childInterruptible: Bool

    /// - Parameters:
    ///   - parent: The fiber running the operator.
    ///   - inheritInterruptibility: Whether children start with the parent's current
    ///     interruptibility (forEach) or always interruptible (race).
    init(parent: FiberRuntime, inheritInterruptibility: Bool) {
        self.parent = parent
        self.childInterruptible = inheritInterruptibility ? parent.isInterruptible : true
    }

    /// Whether any child is still running.
    var hasRunning: Bool { state.withLock { !$0.running.isEmpty } }

    /// Forks `effect` as the child with the given index.
    func fork(_ effect: Effect<A, E>, index: Int) {
        let fiber = Effect<A, E>.unsafeForkDetached(effect, context: parent.context, interruptible: childInterruptible)
        state.withLock { $0.running[index] = fiber }
        fiber.core.observe { exit in
            let waiter = self.state.withLock { state in
                state.running[index] = nil
                state.events.append((index, exit as! Exit<A, E>))
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?()
        }
    }

    /// Waits for the next child to complete. Returns `nil` if the parent fiber is interrupted
    /// while waiting. Must only be called while a child is running or an event is pending.
    func next() async -> (index: Int, exit: Exit<A, E>)? {
        while true {
            let event = state.withLock { state in state.events.isEmpty ? nil : state.events.removeFirst() }
            if let event { return event }
            let signalled: Bool? = await parent.suspend { resume in
                let ready = state.withLock { state -> Bool in
                    if !state.events.isEmpty { return true }
                    state.waiter = { resume(true) }
                    return false
                }
                if ready { resume(true) }
            }
            if signalled == nil { return nil }
        }
    }

    /// Requests interruption of every running child, attributed to the parent.
    func interruptAll() {
        for fiber in state.withLock({ Array($0.running.values) }) {
            fiber.unsafeInterrupt(by: parent.id)
        }
    }

    /// Waits (uninterruptibly) until every child has completed.
    func awaitAll() async {
        for fiber in state.withLock({ Array($0.running.values) }) {
            _ = await fiber.core.waitForExit()
        }
    }

    /// Interrupts every running child and waits for all of them.
    func shutdown() async {
        interruptAll()
        await awaitAll()
    }
}
