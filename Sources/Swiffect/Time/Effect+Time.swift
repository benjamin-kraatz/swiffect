extension Effect where Success == Void {
    /// An effect that completes after `duration`, using the fiber's ``CurrentClock``.
    /// Sleeping is interruptible.
    public static func sleep(_ duration: Duration) -> Effect {
        Effect<Void, Never>.sleep(duration).widen()
    }
}

extension Effect where Success == Void, Failure == Never {
    /// An infallible effect that completes after `duration`, using the fiber's
    /// ``CurrentClock``. Sleeping is interruptible.
    public static func sleep(_ duration: Duration) -> Effect {
        Effect(unsafe: { fiber in
            await fiber.context.get(CurrentClock.self).sleep(for: duration).unsafeRun(in: fiber)
        })
    }
}

extension Effect where Success == any ClockService, Failure == Never {
    /// The fiber's current clock.
    public static var clock: Effect {
        Effect(unsafe: { fiber in .success(fiber.context.get(CurrentClock.self)) })
    }
}

extension Effect where Success == Int64, Failure == Never {
    /// The current wall-clock time in milliseconds since the Unix epoch, from the fiber's
    /// clock.
    public static var currentTimeMillis: Effect {
        Effect(unsafe: { fiber in .success(fiber.context.get(CurrentClock.self).currentTimeMillisUnsafe()) })
    }

    /// The current wall-clock time in nanoseconds since the Unix epoch, from the fiber's
    /// clock.
    public static var currentTimeNanos: Effect {
        Effect(unsafe: { fiber in .success(fiber.context.get(CurrentClock.self).currentTimeNanosUnsafe()) })
    }
}

extension Effect {
    /// Runs the effect after waiting for `duration`.
    public func delay(_ duration: Duration) -> Effect {
        Effect<Void, Failure>.sleep(duration).andThen(self)
    }

    /// Runs the effect and measures how long it took on the fiber's clock.
    public var timed: Effect<(duration: Duration, value: Success), Failure> {
        Effect<(duration: Duration, value: Success), Failure>(unsafe: { fiber in
            let clock = fiber.context.get(CurrentClock.self)
            let start = clock.monotonicNowUnsafe()
            let exit = await self.unsafeRun(in: fiber)
            let elapsed = clock.monotonicNowUnsafe() - start
            return exit.map { (elapsed, $0) }
        })
    }

    /// Returns `nil` if the effect does not complete within `duration`. The effect is
    /// interrupted (and awaited) when the time limit elapses first.
    public func timeoutOption(_ duration: Duration) -> Effect<Success?, Failure> {
        map { Optional($0) }.raceFirst(Effect<Void, Failure>.sleep(duration).as(nil))
    }

    /// Runs `orElse` if the effect does not complete within `duration`. The effect is
    /// interrupted (and awaited) when the time limit elapses first.
    public func timeoutOrElse(_ duration: Duration, orElse: @escaping @Sendable () -> Effect) -> Effect {
        timeoutOption(duration).flatMap { value in value.map { .succeed($0) } ?? orElse() }
    }

    /// Fails with `error()` if the effect does not complete within `duration`. The effect is
    /// interrupted (and awaited) when the time limit elapses first.
    public func timeoutFail(_ duration: Duration, error: @escaping @Sendable () -> Failure) -> Effect {
        timeoutOrElse(duration) { .fail(error()) }
    }
}

extension Effect where Failure == Never {
    /// Fails with ``TimeoutError`` if the effect does not complete within `duration`. The
    /// effect is interrupted (and awaited) when the time limit elapses first.
    ///
    /// ```swift
    /// let response = try await request.timeout(.seconds(5)).run()
    /// ```
    public func timeout(_ duration: Duration) -> Effect<Success, TimeoutError> {
        widen(to: TimeoutError.self).timeoutFail(duration) { TimeoutError(duration: duration) }
    }
}

extension Effect where Failure == TimeoutError {
    /// Fails with ``TimeoutError`` if the effect does not complete within `duration`.
    public func timeout(_ duration: Duration) -> Effect {
        timeoutFail(duration) { TimeoutError(duration: duration) }
    }
}

extension Effect where Failure == any Error {
    /// Fails with ``TimeoutError`` if the effect does not complete within `duration`.
    public func timeout(_ duration: Duration) -> Effect {
        timeoutFail(duration) { TimeoutError(duration: duration) }
    }
}
