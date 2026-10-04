extension Effect {
    /// Runs `finalizer` with the exit of the effect once it completes, however it completes.
    ///
    /// The effect itself keeps the interruptibility of the surrounding region; the finalizer
    /// always runs uninterruptibly. If the finalizer dies, its defects are added to the
    /// effect's cause (a successful effect then fails with them).
    ///
    /// ```swift
    /// let logged = work.onExit { exit in .sync { print("finished:", exit.isSuccess) } }
    /// ```
    public func onExit(_ finalizer: @escaping @Sendable (Exit<Success, Failure>) -> Effect<Void, Never>) -> Effect {
        Effect.uninterruptibleMask { restore in
            Effect(unsafe: { fiber in
                let exit = await restore(self).unsafeRun(in: fiber)
                let finalized = await fiber.runUninterruptibly(finalizer(exit))
                switch (exit, finalized) {
                case (_, .success):
                    return exit
                case (.success, .failure(let cause)):
                    return .failure(cause.widen())
                case (.failure(let cause), .failure(let finalizerCause)):
                    return .failure(cause + finalizerCause.widen())
                }
            })
        }
    }

    /// Runs `finalizer` after the effect, however it completes. See ``onExit(_:)``.
    public func ensuring(_ finalizer: Effect<Void, Never>) -> Effect {
        onExit { _ in finalizer }
    }

    /// Runs `finalizer` with the cause if the effect fails, dies or is interrupted.
    public func onError(_ finalizer: @escaping @Sendable (Cause<Failure>) -> Effect<Void, Never>) -> Effect {
        onExit { exit in
            if case .failure(let cause) = exit { return finalizer(cause) }
            return .void
        }
    }

    /// Runs `finalizer` with the interruptors if the effect is interrupted.
    public func onInterrupt(_ finalizer: @escaping @Sendable (Set<FiberID>) -> Effect<Void, Never>) -> Effect {
        onExit { exit in
            if case .failure(let cause) = exit, cause.hasInterrupts { return finalizer(cause.interruptors) }
            return .void
        }
    }

    /// Runs `finalizer` if the effect is interrupted.
    public func onInterrupt(_ finalizer: Effect<Void, Never>) -> Effect {
        onInterrupt { _ in finalizer }
    }
}
