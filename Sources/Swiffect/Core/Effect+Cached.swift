import Synchronization

extension Effect {
    /// Returns an effect that memoizes `self`: the first run evaluates it, every later run
    /// returns the same outcome (success or failure).
    ///
    /// The evaluation happens on a detached fiber started by the first caller (with that
    /// caller's context), so interrupting one waiting caller neither cancels the computation
    /// nor affects other callers.
    ///
    /// ```swift
    /// let config = try await loadConfig.cached.run()   // Effect<Config, ConfigError>
    /// let a = try await config.run()                   // loads
    /// let b = try await config.run()                   // reuses
    /// ```
    public var cached: Effect<Effect, Never> {
        .sync {
            let memo = Memo<Success, Failure>()
            return Effect(unsafe: { fiber in
                let source = memo.fiber { Effect.unsafeForkDetached(self, context: fiber.context) }
                return await source.join.unsafeRun(in: fiber)
            })
        }
    }
}

private final class Memo<Success: Sendable, Failure: Error>: Sendable {
    private let state = Mutex<Fiber<Success, Failure>?>(nil)

    func fiber(orStart start: () -> Fiber<Success, Failure>) -> Fiber<Success, Failure> {
        state.withLock { current in
            if let current { return current }
            let started = start()
            current = started
            return started
        }
    }
}
