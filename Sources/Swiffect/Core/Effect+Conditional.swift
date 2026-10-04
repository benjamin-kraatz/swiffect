extension Effect {
    /// Runs the effect only if `condition` holds when it is run; returns `nil` otherwise.
    ///
    /// ```swift
    /// let maybeSent = sendEmail(user).when(user.wantsEmail)
    /// ```
    public func when(_ condition: @escaping @autoclosure @Sendable () -> Bool) -> Effect<Success?, Failure> {
        Effect<Success?, Failure>.suspend {
            condition() ? self.map { Optional($0) } : .succeed(nil)
        }
    }

    /// Runs the effect only if the effectful `condition` succeeds with `true`; returns `nil`
    /// otherwise.
    public func when(_ condition: Effect<Bool, Failure>) -> Effect<Success?, Failure> {
        condition.flatMap { holds in holds ? self.map { Optional($0) } : .succeed(nil) }
    }

    /// Fails with `orFailWith(value)` unless the success value satisfies `predicate`.
    public func filterOrFail(
        _ predicate: @escaping @Sendable (Success) -> Bool,
        orFailWith error: @escaping @Sendable (Success) -> Failure
    ) -> Effect {
        flatMap { value in predicate(value) ? .succeed(value) : .fail(error(value)) }
    }

    /// Tries the effects in order and returns the first success. If all fail, fails with the
    /// last failure. Dies if `effects` is empty.
    public static func firstSuccessOf(_ effects: [Effect]) -> Effect {
        guard var result = effects.last else {
            return .die(RuntimeError("firstSuccessOf requires at least one effect"))
        }
        for effect in effects.dropLast().reversed() {
            let fallback = result
            result = effect.catchAll { _ in fallback }
        }
        return result
    }
}
