/// A handle to a running (or completed) fiber, a lightweight thread of execution that runs one
/// effect on its own Swift `Task`.
///
/// Obtain fibers by forking (``Effect/forkChild``, ``Effect/forkDetach``,
/// ``Effect/forkScoped``, ``Effect/forkIn(_:)``) or with ``Effect/runFork(context:)``.
/// Observing a fiber never affects it; ``interrupt`` requests interruption and waits for the
/// fiber to finish (including its finalizers).
///
/// ```swift
/// let program: Effect<Int, Never> = .gen { bind in
///     let fiber = try await bind(Effect.succeed(21).map { $0 * 2 }.forkChild)
///     return try await bind(fiber.join)
/// }
/// ```
///
/// `Fiber` is a value type; copies refer to the same fiber. All members are thread-safe.
public struct Fiber<Success: Sendable, Failure: Error>: Sendable, Hashable {
    let core: FiberCore

    init(core: FiberCore) {
        self.core = core
    }

    /// The fiber's identifier.
    public var id: FiberID { core.id }

    /// Waits for the fiber to complete and returns its exit. Waiting is interruptible; being
    /// interrupted while waiting does not affect the observed fiber.
    public var await: Effect<Exit<Success, Failure>, Never> {
        let core = self.core
        return Effect<Exit<Success, Failure>, Never>.callback { resume in
            let token = core.observe { exit in resume(.succeed(exit as! Exit<Success, Failure>)) }
            guard let token else { return nil }
            return .sync { core.removeObserver(token) }
        }
    }

    /// Waits for the fiber to complete and continues with its outcome: its value, or its
    /// complete failure cause.
    public var join: Effect<Success, Failure> {
        self.await.flatMap { exit in Effect.fromExit(exit) }
    }

    /// Interrupts the fiber and waits until it has completed (finalizers included). The
    /// interruption is attributed to the calling fiber.
    ///
    /// A fiber must not interrupt itself this way: it would wait for its own completion.
    public var interrupt: Effect<Void, Never> {
        let core = self.core
        return Effect<Void, Never>(unsafe: { fiber in
            core.interrupt(by: fiber.id)
            return await self.await.asVoid.unsafeRun(in: fiber)
        })
    }

    /// Returns the exit if the fiber has completed, without waiting.
    public var poll: Effect<Exit<Success, Failure>?, Never> {
        .sync { self.unsafePoll() }
    }

    /// Returns the exit if the fiber has completed, without waiting.
    public func unsafePoll() -> Exit<Success, Failure>? {
        core.exit.map { $0 as! Exit<Success, Failure> }
    }

    /// Requests interruption without waiting for the fiber to complete.
    ///
    /// - Parameter interruptor: The fiber recorded as the interruptor, if any.
    public func unsafeInterrupt(by interruptor: FiberID? = nil) {
        core.interrupt(by: interruptor)
    }

    /// Registers `observer` to be called once with the fiber's exit, on the thread that
    /// completes the fiber (or immediately if it has already completed). Returns a closure
    /// that unregisters the observer.
    @discardableResult
    public func unsafeAddObserver(
        _ observer: @escaping @Sendable (Exit<Success, Failure>) -> Void
    ) -> @Sendable () -> Void {
        let core = self.core
        guard let token = core.observe({ observer($0 as! Exit<Success, Failure>) }) else { return {} }
        return { core.removeObserver(token) }
    }

    /// Waits (as a plain Swift `async` call) for the fiber to complete and returns its exit.
    /// Not cancellable: cancelling the calling task does not interrupt the fiber.
    public var exit: Exit<Success, Failure> {
        get async { await core.waitForExit() as! Exit<Success, Failure> }
    }

    public static func == (lhs: Fiber, rhs: Fiber) -> Bool {
        lhs.core === rhs.core
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
