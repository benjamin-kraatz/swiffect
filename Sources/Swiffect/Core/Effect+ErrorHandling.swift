extension Effect {
    /// Recovers from typed failures (Effect's `catch`). The handler receives the first typed
    /// failure; defects and interruptions propagate unchanged.
    ///
    /// ```swift
    /// let user = fetchUser(1).catchAll { error in
    ///     error == .notFound ? .succeed(.guest) : .fail(error)
    /// }
    /// ```
    public func catchAll<E2: Error>(
        _ handler: @escaping @Sendable (Failure) -> Effect<Success, E2>
    ) -> Effect<Success, E2> {
        matchEffect(onFailure: handler, onSuccess: { .succeed($0) })
    }

    /// Recovers from any failure, including defects and interruptions caused by other fibers.
    /// The handler receives the complete cause.
    ///
    /// Like every recovery operator it does not run while the fiber itself is being
    /// interrupted.
    public func catchCause<E2: Error>(
        _ handler: @escaping @Sendable (Cause<Failure>) -> Effect<Success, E2>
    ) -> Effect<Success, E2> {
        matchCauseEffect(onFailure: handler, onSuccess: { .succeed($0) })
    }

    /// Recovers from typed failures that satisfy `predicate`; other failures propagate.
    public func catchIf(
        _ predicate: @escaping @Sendable (Failure) -> Bool,
        _ handler: @escaping @Sendable (Failure) -> Effect
    ) -> Effect {
        catchSome { predicate($0) ? handler($0) : nil }
    }

    /// Recovers from the typed failures for which `handler` returns an effect; when it returns
    /// `nil` the failure propagates (Effect's `catchFilter`).
    public func catchSome(_ handler: @escaping @Sendable (Failure) -> Effect?) -> Effect {
        catchCause { cause in
            if let failure = cause.firstFailure, let recovered = handler(failure) { return recovered }
            return .failCause(cause)
        }
    }

    /// Recovers from defects. The handler receives the first defect; typed failures and
    /// interruptions propagate.
    public func catchDefect(_ handler: @escaping @Sendable (any Error) -> Effect) -> Effect {
        catchCause { cause in
            if let defect = cause.firstDefect { return handler(defect) }
            return .failCause(cause)
        }
    }

    /// Runs `that` when `self` fails with a typed failure.
    public func orElse<E2: Error>(_ that: @escaping @Sendable () -> Effect<Success, E2>) -> Effect<Success, E2> {
        catchAll { _ in that() }
    }

    /// Replaces typed failures with a fallback value.
    public func orElseSucceed(_ value: @escaping @autoclosure @Sendable () -> Success) -> Effect<Success, Never> {
        catchAll { _ in .succeed(value()) }
    }

    /// Ignores the outcome: typed failures are swallowed, defects and interruptions propagate.
    public var ignore: Effect<Void, Never> {
        match(onFailure: { _ in () }, onSuccess: { _ in () })
    }

    /// Transforms the typed failures.
    public func mapError<E2: Error>(_ transform: @escaping @Sendable (Failure) -> E2) -> Effect<Success, E2> {
        Effect<Success, E2>(unsafe: { fiber in await self.unsafeRun(in: fiber).mapError(transform) })
    }

    /// Transforms both the typed failures and the success value.
    public func mapBoth<B: Sendable, E2: Error>(
        onFailure: @escaping @Sendable (Failure) -> E2,
        onSuccess: @escaping @Sendable (Success) -> B
    ) -> Effect<B, E2> {
        Effect<B, E2>(unsafe: { fiber in
            await self.unsafeRun(in: fiber).mapError(onFailure).map(onSuccess)
        })
    }

    /// Turns typed failures into defects, producing an infallible effect.
    public var orDie: Effect<Success, Never> {
        Effect<Success, Never>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): .success(value)
            case .failure(let cause): .failure(cause.failuresAsDefects())
            }
        })
    }

    /// Turns typed failures into the defects returned by `transform`.
    public func orDie(with transform: @escaping @Sendable (Failure) -> any Error) -> Effect<Success, Never> {
        Effect<Success, Never>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): .success(value)
            case .failure(let cause): .failure(cause.failuresAsDefects(transform))
            }
        })
    }

    /// Exposes the complete cause in the typed failure channel.
    public var sandbox: Effect<Success, Cause<Failure>> {
        Effect<Success, Cause<Failure>>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): .success(value)
            case .failure(let cause): .fail(cause)
            }
        })
    }

    /// Runs `effect` with the first typed failure, then fails with the original cause. A
    /// failure of `effect` replaces the original failure.
    public func tapError<X: Sendable>(_ effect: @escaping @Sendable (Failure) -> Effect<X, Failure>) -> Effect {
        catchCause { cause in
            guard let failure = cause.firstFailure else { return .failCause(cause) }
            return effect(failure).andThen(.failCause(cause))
        }
    }

    /// Runs `effect` with the complete cause of any failure, then fails with that cause.
    public func tapCause<X: Sendable>(_ effect: @escaping @Sendable (Cause<Failure>) -> Effect<X, Failure>) -> Effect {
        catchCause { cause in effect(cause).andThen(.failCause(cause)) }
    }

    /// Runs `effect` with the first defect, then fails with the original cause.
    public func tapDefect<X: Sendable>(_ effect: @escaping @Sendable (any Error) -> Effect<X, Failure>) -> Effect {
        catchCause { cause in
            guard let defect = cause.firstDefect else { return .failCause(cause) }
            return effect(defect).andThen(.failCause(cause))
        }
    }
}

extension Effect {
    /// Restores a sandboxed effect: the cause in the failure channel becomes the cause again.
    public func unsandbox<E: Error>() -> Effect<Success, E> where Failure == Cause<E> {
        Effect<Success, E>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value):
                return .success(value)
            case .failure(let cause):
                let flattened = cause.reasons.reduce(Cause<E>.empty) { result, reason in
                    switch reason {
                    case .fail(let inner): result + inner
                    case .die(let defect): result + .die(defect)
                    case .interrupt(let id): result + .interrupt(id)
                    }
                }
                return .failure(flattened)
            }
        })
    }
}
