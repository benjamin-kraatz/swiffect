extension Effect {
    /// Repeats the effect until it fails. The loop runs in constant stack space and checks for
    /// interruption before every iteration.
    ///
    /// ```swift
    /// let heartbeat = ping.andThen(Effect.sleep(.seconds(1))).forever
    /// ```
    public var forever: Effect<Never, Failure> {
        Effect<Never, Failure>(unsafe: { fiber in
            while true {
                if case .failure(let cause) = await self.unsafeRun(in: fiber) { return .failure(cause) }
            }
        })
    }

    /// Returns `count` copies of the effect.
    public func replicate(_ count: Int) -> [Effect] {
        Array(repeating: self, count: max(0, count))
    }

    /// Retries the effect until it succeeds, yielding between attempts. Defects and
    /// interruptions are not retried.
    public var eventually: Effect<Success, Never> {
        Effect<Success, Never>(unsafe: { fiber in
            while true {
                switch await self.unsafeRun(in: fiber) {
                case .success(let value):
                    return .success(value)
                case .failure(let cause):
                    if let skipped: Cause<Never> = fiber.skippedRecovery(cause) { return .failure(skipped) }
                    guard cause.hasFails else { return .failure(cause.stripFailures()) }
                    await Task.yield()
                }
            }
        })
    }
}
