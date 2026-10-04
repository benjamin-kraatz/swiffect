/// The running fiber as seen from inside an effect: its identity, interruption state and the
/// ``Context`` in effect at this point of the program.
///
/// A `FiberRuntime` is handed to low-level effect bodies (``Effect/init(unsafe:)``,
/// ``Effect/withFiber(_:)``) and to the ``Bind`` of ``Effect/gen(_:)``. It is the hook for
/// writing new primitives: read services from ``context``, check ``isInterruptible``, park the
/// fiber with ``suspend(_:)`` and run nested effects with ``Effect/unsafeRun(in:)``.
///
/// A runtime value belongs to the fiber that received it. Using it from another fiber or
/// task (for example by escaping it into a detached `Task`) breaks the guarantee that a fiber
/// executes one operation at a time.
public struct FiberRuntime: Sendable {
    let core: FiberCore

    /// The context visible at this point of the fiber.
    public let context: Context

    init(core: FiberCore, context: Context) {
        self.core = core
        self.context = context
    }

    /// The identifier of the running fiber.
    public var id: FiberID { core.id }

    /// Whether the fiber is currently in an interruptible region.
    public var isInterruptible: Bool { core.isInterruptible }

    /// Whether an interruption has been requested. Interruption is sticky: once requested it
    /// stays pending until the fiber completes.
    public var isInterrupted: Bool { core.isInterrupted }

    /// Whether the fiber must stop at the next operator boundary, i.e. it is interrupted and
    /// currently interruptible.
    public var shouldInterrupt: Bool { core.shouldInterrupt }

    /// The accumulated interruption cause (empty if the fiber was never interrupted).
    public var interruptCause: Cause<Never> { core.interruptCause }

    /// Returns the same fiber with a different context. Used to run a nested effect with
    /// extra or replaced services.
    public func withContext(_ context: Context) -> FiberRuntime {
        FiberRuntime(core: core, context: context)
    }

    /// Returns the same fiber with its context transformed by `update`.
    public func updatingContext(_ update: (Context) -> Context) -> FiberRuntime {
        FiberRuntime(core: core, context: update(context))
    }

    /// Parks the fiber until `register`'s `resume` callback is invoked, and returns the value
    /// passed to it.
    ///
    /// `register` is called synchronously and may call `resume` immediately or later from any
    /// thread; only the first call has an effect. If the fiber is interruptible when it
    /// suspends, an interruption wakes it immediately and `suspend` returns `nil` (a later
    /// `resume` is then ignored). In an uninterruptible region the fiber waits for `resume`
    /// no matter what.
    public func suspend<T: Sendable>(
        _ register: (_ resume: @escaping @Sendable (T) -> Void) -> Void
    ) async -> T? {
        let suspension = Suspension<T>()
        register { value in suspension.complete(value) }
        let interruptible = core.isInterruptible
        if interruptible, !core.installWaker({ suspension.complete(nil) }) {
            suspension.complete(nil)
        }
        let result = await suspension.wait()
        if interruptible { core.clearWaker() }
        return result
    }

    /// The exit an interrupted fiber produces: a failure with the accumulated interrupt cause.
    public func interruptedExit<A, E>() -> Exit<A, E> {
        .failure(core.interruptCause.widen())
    }

    /// Runs `effect` with interruption disabled, restoring the previous interruptibility
    /// afterwards. Unlike ``Effect/uninterruptible`` this does not convert the result into an
    /// interruption when interruptibility is restored; callers decide what to do.
    func runUninterruptibly<A, E>(_ effect: Effect<A, E>) async -> Exit<A, E> {
        guard core.isInterruptible else { return await effect.unsafeRun(in: self) }
        core.setInterruptible(false)
        let exit = await effect.unsafeRun(in: self)
        core.setInterruptible(true)
        return exit
    }

    /// Returns the cause a recovery handler must propagate instead of running, or `nil` if the
    /// handler may run. Handlers are skipped while the fiber is interrupted and interruptible:
    /// a fiber cannot catch its own interruption.
    func skippedRecovery<E, E2>(_ cause: Cause<E>) -> Cause<E2>? {
        guard core.shouldInterrupt else { return nil }
        var kept = cause.stripFailures()
        if !kept.hasInterrupts { kept = core.interruptCause + kept }
        return kept.widen()
    }
}
