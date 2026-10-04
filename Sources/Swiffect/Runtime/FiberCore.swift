import Synchronization

/// The mutable heart of a fiber: identity, interruption state, children, observers and the
/// final exit.
///
/// Thread-safety: the interruption flags are atomics and everything else lives behind a
/// `Mutex`. Only the fiber's own task changes the interruptible flag; any thread may interrupt
/// the fiber, observe it or read its exit. Callbacks (wakers, observers) are always invoked
/// outside the lock.
final class FiberCore: Sendable {
    let id: FiberID

    private let interruptedFlag = Atomic<Bool>(false)
    private let interruptibleFlag: Atomic<Bool>
    private let opCount = Atomic<UInt32>(0)
    private let state = Mutex(State())

    private struct State {
        var interruptCause = Cause<Never>.empty
        var waker: (@Sendable () -> Void)?
        var exit: (any Sendable)?
        var observers: [UInt64: @Sendable (any Sendable) -> Void] = [:]
        var nextObserverID: UInt64 = 0
        var children: [FiberID: FiberCore] = [:]
        var parent: FiberCore?
    }

    init(interruptible: Bool = true) {
        id = .next()
        interruptibleFlag = Atomic(interruptible)
    }

    // MARK: Interruption

    /// Whether interruption is currently delivered to this fiber.
    var isInterruptible: Bool { interruptibleFlag.load(ordering: .relaxed) }

    /// Changes the interruptible flag. Must only be called from the fiber's own task.
    func setInterruptible(_ value: Bool) {
        interruptibleFlag.store(value, ordering: .relaxed)
    }

    /// Whether an interruption has been requested (it is sticky).
    var isInterrupted: Bool { interruptedFlag.load(ordering: .acquiring) }

    /// Whether the fiber must stop at the next operator boundary.
    var shouldInterrupt: Bool { isInterrupted && isInterruptible }

    /// The accumulated interruption cause (empty if never interrupted).
    var interruptCause: Cause<Never> { state.withLock { $0.interruptCause } }

    /// Requests interruption. Records `interruptor` in the sticky interrupt cause and wakes the
    /// fiber if it is suspended interruptibly. Has no effect once the fiber has completed.
    func interrupt(by interruptor: FiberID?) {
        let waker: (@Sendable () -> Void)? = state.withLock { state in
            guard state.exit == nil else { return nil }
            let known = state.interruptCause.reasons.contains { reason in
                if case .interrupt(let id) = reason { id == interruptor } else { false }
            }
            if !known { state.interruptCause = state.interruptCause + .interrupt(interruptor) }
            interruptedFlag.store(true, ordering: .releasing)
            defer { state.waker = nil }
            return state.waker
        }
        waker?()
    }

    /// Installs the closure that wakes the current interruptible suspension. Returns `false`
    /// (and installs nothing) if the fiber has already been interrupted.
    func installWaker(_ waker: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state in
            guard state.interruptCause.isEmpty else { return false }
            state.waker = waker
            return true
        }
    }

    /// Removes the waker installed by ``installWaker(_:)``.
    func clearWaker() {
        state.withLock { $0.waker = nil }
    }

    /// Returns `true` every 2048 operations so long-running synchronous loops yield the thread.
    func shouldYield() -> Bool {
        opCount.wrappingAdd(1, ordering: .relaxed).newValue & 2047 == 0
    }

    // MARK: Children

    /// Registers `child` so it is interrupted and awaited before this fiber completes.
    func addChild(_ child: FiberCore) {
        child.state.withLock { $0.parent = self }
        state.withLock { $0.children[child.id] = child }
    }

    private func removeChild(_ id: FiberID) {
        state.withLock { _ = $0.children.removeValue(forKey: id) }
    }

    /// A snapshot of the children that are still running.
    var children: [FiberCore] {
        state.withLock { Array($0.children.values) }
    }

    // MARK: Observation

    /// The final exit (an `Exit<A, E>` boxed as `any Sendable`), if the fiber has completed.
    var exit: (any Sendable)? { state.withLock { $0.exit } }

    /// Registers `observer` to be called with the exit. If the fiber has already completed the
    /// observer is called immediately and `nil` is returned; otherwise returns a token for
    /// ``removeObserver(_:)``.
    @discardableResult
    func observe(_ observer: @escaping @Sendable (any Sendable) -> Void) -> UInt64? {
        let registration: Result<UInt64, ExitBox> = state.withLock { state in
            if let exit = state.exit { return .failure(ExitBox(exit: exit)) }
            state.nextObserverID += 1
            state.observers[state.nextObserverID] = observer
            return .success(state.nextObserverID)
        }
        switch registration {
        case .success(let token):
            return token
        case .failure(let done):
            observer(done.exit)
            return nil
        }
    }

    private struct ExitBox: Error {
        let exit: any Sendable
    }

    /// Unregisters an observer added with ``observe(_:)``.
    func removeObserver(_ token: UInt64) {
        state.withLock { _ = $0.observers.removeValue(forKey: token) }
    }

    /// Suspends the calling task (uninterruptibly) until the fiber has completed.
    func waitForExit() async -> any Sendable {
        if let exit { return exit }
        return await withUnsafeContinuation { continuation in
            observe { continuation.resume(returning: $0) }
        }
    }

    // MARK: Lifecycle

    /// Starts running `effect` on a new unstructured task.
    func start<A, E>(_ effect: Effect<A, E>, context: Context) {
        Task.detached {
            await self.run(effect, context: context)
        }
    }

    private func run<A, E>(_ effect: Effect<A, E>, context: Context) async {
        let exit = await effect.unsafeRun(in: FiberRuntime(core: self, context: context))
        await interruptChildren()
        complete(exit)
    }

    /// Interrupts all remaining children and waits for them, uninterruptibly.
    private func interruptChildren() async {
        setInterruptible(false)
        while true {
            let children = self.children
            if children.isEmpty { return }
            for child in children { child.interrupt(by: id) }
            for child in children { _ = await child.waitForExit() }
        }
    }

    /// Publishes the exit, detaches from the parent and notifies observers.
    private func complete(_ exit: any Sendable) {
        let (observers, parent) = state.withLock { state in
            state.exit = exit
            state.waker = nil
            state.children = [:]
            let observers = state.observers.sorted { $0.key < $1.key }.map(\.value)
            state.observers = [:]
            let parent = state.parent
            state.parent = nil
            return (observers, parent)
        }
        parent?.removeChild(id)
        for observer in observers { observer(exit) }
    }
}
