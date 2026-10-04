extension Effect {
    /// Transforms the success value.
    ///
    /// ```swift
    /// let doubled = Effect.succeed(21).map { $0 * 2 }
    /// ```
    public func map<B: Sendable>(_ transform: @escaping @Sendable (Success) -> B) -> Effect<B, Failure> {
        Effect<B, Failure>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): .success(transform(value))
            case .failure(let cause): .failure(cause)
            }
        })
    }

    /// Runs `self`, then the effect produced from its value. Failures short-circuit.
    ///
    /// ```swift
    /// let user = fetchID().flatMap { id in fetchUser(id) }
    /// ```
    public func flatMap<B: Sendable>(
        _ next: @escaping @Sendable (Success) -> Effect<B, Failure>
    ) -> Effect<B, Failure> {
        Effect<B, Failure>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): await next(value).unsafeRun(in: fiber)
            case .failure(let cause): .failure(cause)
            }
        })
    }

    /// Runs `self`, then an infallible effect produced from its value.
    @_disfavoredOverload
    public func flatMap<B: Sendable>(
        _ next: @escaping @Sendable (Success) -> Effect<B, Never>
    ) -> Effect<B, Failure> {
        flatMap { value in next(value).widen(to: Failure.self) }
    }

    /// Runs `self`, discards its value and runs `next`.
    public func andThen<B: Sendable>(_ next: Effect<B, Failure>) -> Effect<B, Failure> {
        flatMap { _ in next }
    }

    /// Runs `self`, discards its value and runs the infallible effect `next`.
    @_disfavoredOverload
    public func andThen<B: Sendable>(_ next: Effect<B, Never>) -> Effect<B, Failure> {
        flatMap { _ in next.widen(to: Failure.self) }
    }

    /// Runs a side effect with the success value and keeps the original value. A failure of
    /// the side effect fails the whole effect.
    ///
    /// ```swift
    /// let user = fetchUser(1).tap { user in Effect.sync { print(user.name) } }
    /// ```
    public func tap<X: Sendable>(_ effect: @escaping @Sendable (Success) -> Effect<X, Failure>) -> Effect {
        flatMap { value in effect(value).as(value) }
    }

    /// Runs an infallible side effect with the success value and keeps the original value.
    @_disfavoredOverload
    public func tap<X: Sendable>(_ effect: @escaping @Sendable (Success) -> Effect<X, Never>) -> Effect {
        flatMap { value in effect(value).widen(to: Failure.self).as(value) }
    }

    /// Replaces the success value with `value`.
    public func `as`<B: Sendable>(_ value: B) -> Effect<B, Failure> {
        map { _ in value }
    }

    /// Discards the success value.
    public var asVoid: Effect<Void, Failure> {
        map { _ in () }
    }

    /// Runs the effect produced by `self`.
    public func flatten<B: Sendable>() -> Effect<B, Failure> where Success == Effect<B, Failure> {
        flatMap { $0 }
    }
}

extension Effect where Success: Error {
    /// Swaps the success and the typed failure channels. Defects and interruptions are kept.
    public var flip: Effect<Failure, Success> {
        Effect<Failure, Success>(unsafe: { fiber in
            switch await self.unsafeRun(in: fiber) {
            case .success(let value): .fail(value)
            case .failure(let cause):
                if cause.hasFailsOnly, let failure = cause.firstFailure {
                    .success(failure)
                } else {
                    .failure(cause.stripFailures().widen())
                }
            }
        })
    }
}

extension Effect where Failure == Never {
    /// Converts an infallible effect into an effect with any failure type.
    public func widen<E: Error>(to _: E.Type = E.self) -> Effect<Success, E> {
        Effect<Success, E>(unsafe: { fiber in await self.unsafeRun(in: fiber).widen() })
    }

    /// Runs `self`, then a (possibly failing) effect produced from its value.
    @_disfavoredOverload
    public func flatMap<B: Sendable, E: Error>(
        _ next: @escaping @Sendable (Success) -> Effect<B, E>
    ) -> Effect<B, E> {
        widen(to: E.self).flatMap(next)
    }

    /// Runs `self`, discards its value and runs the (possibly failing) effect `next`.
    @_disfavoredOverload
    public func andThen<B: Sendable, E: Error>(_ next: Effect<B, E>) -> Effect<B, E> {
        widen(to: E.self).andThen(next)
    }
}
