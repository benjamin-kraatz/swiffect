extension Effect {
    /// Starts the effect on a new root fiber and returns its handle immediately.
    ///
    /// The fiber runs on its own unstructured Swift `Task` and is not tied to the caller:
    /// interrupt it with ``Fiber/unsafeInterrupt(by:)`` or ``Fiber/interrupt``.
    ///
    /// - Parameter context: The services available to the effect.
    @discardableResult
    public func runFork(context: Context = Context()) -> Fiber<Success, Failure> {
        Self.unsafeForkDetached(self, context: context)
    }

    /// Runs the effect on a new root fiber and returns its exit.
    ///
    /// Cancelling the calling Swift task interrupts the fiber; the call still waits until the
    /// fiber has completed (finalizers included) and returns the resulting exit.
    ///
    /// ```swift
    /// switch await program.runExit() {
    /// case .success(let value): print(value)
    /// case .failure(let cause): print(cause.pretty)
    /// }
    /// ```
    public func runExit(context: Context = Context()) async -> Exit<Success, Failure> {
        let fiber = runFork(context: context)
        return await withTaskCancellationHandler {
            await fiber.exit
        } onCancel: {
            fiber.unsafeInterrupt()
        }
    }

    /// Runs the effect on a new root fiber and returns its value, or throws.
    ///
    /// A plain failure (only typed failures) throws the first `Failure` value itself; any
    /// other cause throws a ``FiberFailure``. Cancelling the calling Swift task interrupts the
    /// fiber, which then typically throws a ``FiberFailure`` whose cause is an interruption.
    ///
    /// ```swift
    /// do {
    ///     let user = try await fetchUser(42).run(context: services)
    /// } catch let error as UserError {
    ///     // typed failure
    /// }
    /// ```
    public func run(context: Context = Context()) async throws -> Success {
        try await runExit(context: context).get()
    }
}
