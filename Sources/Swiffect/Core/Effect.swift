/// A lazy, immutable description of a program that, when run by a fiber, either succeeds with a
/// `Success` value or fails with a ``Cause`` of `Failure`.
///
/// Effects do nothing until they are run (``Effect/run(context:)``,
/// ``Effect/runExit(context:)``, ``Effect/runFork(context:)``). They can be run any number of
/// times and composed freely:
///
/// ```swift
/// let program: Effect<Int, MyError> = .gen { bind in
///     let user = try await bind(fetchUser(42))
///     try await bind(Effect.sleep(.milliseconds(10)))
///     return user.age
/// }
/// let age = try await program.run()
/// ```
///
/// `Failure == Never` describes an effect that cannot fail with a typed error (it can still die
/// or be interrupted). Services are not tracked in the type: they are resolved at runtime from
/// the fiber's ``Context`` (see ``Effect/service(_:)``).
///
/// Interruption is checked at every operator boundary, i.e. before each nested effect starts.
public struct Effect<Success: Sendable, Failure: Error>: Sendable {
    let body: @Sendable (FiberRuntime) async -> Exit<Success, Failure>

    /// Creates a primitive effect from a closure that receives the running fiber.
    ///
    /// This is the extension point for writing new primitives. The closure runs on the fiber's
    /// task; it must run nested effects with ``unsafeRun(in:)``, must not escape the
    /// ``FiberRuntime``, and must return promptly or suspend through
    /// ``FiberRuntime/suspend(_:)`` (or ``Effect/callback(_:)``) so interruption can wake it.
    ///
    /// ```swift
    /// let currentID = Effect<FiberID, Never>(unsafe: { fiber in .success(fiber.id) })
    /// ```
    public init(unsafe body: @escaping @Sendable (_ fiber: FiberRuntime) async -> Exit<Success, Failure>) {
        self.body = body
    }

    /// Runs the effect inline on the given fiber and returns its exit.
    ///
    /// This is the low-level counterpart of ``init(unsafe:)``. If the fiber is interrupted and
    /// interruptible the effect does not start and the interrupt cause is returned instead.
    /// Long synchronous chains periodically yield the underlying thread.
    public func unsafeRun(in fiber: FiberRuntime) async -> Exit<Success, Failure> {
        let core = fiber.core
        if core.shouldYield() { await Task.yield() }
        if core.shouldInterrupt { return fiber.interruptedExit() }
        return await body(fiber)
    }
}
