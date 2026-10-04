// Matching is the foundation of every recovery operator. All of them share one rule: while the
// fiber is interrupted and interruptible, failure handlers are skipped and the interruption
// keeps propagating, so a fiber cannot catch its own interruption.

extension Effect {
    /// Continues with `onSuccess` or `onFailure` depending on the outcome. `onFailure` sees the
    /// complete cause: typed failures, defects and interruptions.
    public func matchCauseEffect<B: Sendable, E2: Error>(
        onFailure: @escaping @Sendable (Cause<Failure>) -> Effect<B, E2>,
        onSuccess: @escaping @Sendable (Success) -> Effect<B, E2>
    ) -> Effect<B, E2> {
        Effect<B, E2>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value):
                return await onSuccess(value).unsafeRun(in: fiber)
            case .failure(let cause):
                if let skipped: Cause<E2> = fiber.skippedRecovery(cause) { return .failure(skipped) }
                return await onFailure(cause).unsafeRun(in: fiber)
            }
        })
    }

    /// Folds the outcome, including defects and interruptions, into a value.
    public func matchCause<B: Sendable>(
        onFailure: @escaping @Sendable (Cause<Failure>) -> B,
        onSuccess: @escaping @Sendable (Success) -> B
    ) -> Effect<B, Never> {
        matchCauseEffect(
            onFailure: { .succeed(onFailure($0)) },
            onSuccess: { .succeed(onSuccess($0)) }
        )
    }

    /// Continues with `onSuccess` or `onFailure`. Only typed failures reach `onFailure` (it
    /// receives the first one); defects and interruptions propagate.
    public func matchEffect<B: Sendable, E2: Error>(
        onFailure: @escaping @Sendable (Failure) -> Effect<B, E2>,
        onSuccess: @escaping @Sendable (Success) -> Effect<B, E2>
    ) -> Effect<B, E2> {
        matchCauseEffect(
            onFailure: { cause in
                if let failure = cause.firstFailure { return onFailure(failure) }
                return .failCause(cause.stripFailures().widen())
            },
            onSuccess: onSuccess
        )
    }

    /// Folds the outcome into a value. Only typed failures reach `onFailure`; defects and
    /// interruptions propagate.
    ///
    /// ```swift
    /// let message = fetchUser(1).match(
    ///     onFailure: { "failed: \($0)" },
    ///     onSuccess: { "hello \($0.name)" }
    /// )
    /// ```
    public func match<B: Sendable>(
        onFailure: @escaping @Sendable (Failure) -> B,
        onSuccess: @escaping @Sendable (Success) -> B
    ) -> Effect<B, Never> {
        matchEffect(
            onFailure: { .succeed(onFailure($0)) },
            onSuccess: { .succeed(onSuccess($0)) }
        )
    }

    /// Captures the complete outcome as an ``Exit``. The resulting effect only fails if the
    /// fiber itself is interrupted.
    public var exit: Effect<Exit<Success, Failure>, Never> {
        matchCause(onFailure: { .failure($0) }, onSuccess: { .success($0) })
    }

    /// Captures typed failures as a `Result`. Defects and interruptions propagate.
    public var result: Effect<Result<Success, Failure>, Never> {
        match(onFailure: { .failure($0) }, onSuccess: { .success($0) })
    }

    /// Converts typed failures into `nil`. Defects and interruptions propagate.
    public var option: Effect<Success?, Never> {
        match(onFailure: { _ in nil }, onSuccess: { $0 })
    }
}
