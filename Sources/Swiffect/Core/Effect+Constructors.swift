extension Effect {
    /// An effect that succeeds with `value`.
    ///
    /// The failure type is inferred from context; without context it defaults to `Never`.
    public static func succeed(_ value: Success) -> Effect {
        Effect(unsafe: { _ in .success(value) })
    }

    /// An effect that fails with the typed error `error`.
    public static func fail(_ error: Failure) -> Effect {
        Effect(unsafe: { _ in .fail(error) })
    }

    /// An effect that fails with the given cause.
    public static func failCause(_ cause: Cause<Failure>) -> Effect {
        Effect(unsafe: { _ in .failure(cause) })
    }

    /// An effect that dies with the defect `defect`.
    ///
    /// Defects are unexpected errors. They are not part of the typed failure channel and are
    /// only observable through causes (``catchCause(_:)``, ``catchDefect(_:)``, ``exit``).
    public static func die(_ defect: any Error) -> Effect {
        Effect(unsafe: { _ in .die(defect) })
    }

    /// An effect that dies with a ``RuntimeError`` carrying `message`.
    public static func die(message: String) -> Effect {
        die(RuntimeError(message))
    }

    /// An effect that completes with the given exit.
    public static func fromExit(_ exit: Exit<Success, Failure>) -> Effect {
        Effect(unsafe: { _ in exit })
    }

    /// An effect that succeeds or fails according to `result`.
    public static func fromResult(_ result: Result<Success, Failure>) -> Effect {
        switch result {
        case .success(let value): succeed(value)
        case .failure(let error): fail(error)
        }
    }

    /// An effect that runs a synchronous side effect each time it is run.
    ///
    /// ```swift
    /// let now = Effect.sync { Counter.shared.next() }
    /// ```
    public static func sync(_ compute: @escaping @Sendable () -> Success) -> Effect {
        Effect(unsafe: { _ in .success(compute()) })
    }

    /// An effect that lazily constructs the effect to run each time it is run.
    ///
    /// Use it for recursion and to defer the construction of an expensive effect.
    public static func suspend(_ make: @escaping @Sendable () -> Effect) -> Effect {
        Effect(unsafe: { fiber in await make().unsafeRun(in: fiber) })
    }

    /// An effect that runs a synchronous, throwing operation. A thrown error becomes the typed
    /// failure (Effect's `try`).
    ///
    /// With typed throws the failure type is inferred from the closure; an untyped closure
    /// yields `Failure == any Error`.
    ///
    /// ```swift
    /// let port = Effect.attempt { () throws(ParseError) in try parsePort(text) }
    /// ```
    public static func attempt(_ operation: @escaping @Sendable () throws(Failure) -> Success) -> Effect {
        Effect(unsafe: { _ in
            do throws(Failure) {
                return .success(try operation())
            } catch {
                return .fail(error)
            }
        })
    }

    /// An effect that runs a synchronous, throwing operation and maps the thrown error into
    /// the typed failure with `mapError`.
    public static func attempt<E: Error>(
        _ operation: @escaping @Sendable () throws(E) -> Success,
        catch mapError: @escaping @Sendable (E) -> Failure
    ) -> Effect {
        Effect(unsafe: { _ in
            do throws(E) {
                return .success(try operation())
            } catch {
                return .fail(mapError(error))
            }
        })
    }

    /// An effect built from the running fiber, e.g. to read its identifier or context.
    public static func withFiber(_ make: @escaping @Sendable (FiberRuntime) -> Effect) -> Effect {
        Effect(unsafe: { fiber in await make(fiber).unsafeRun(in: fiber) })
    }
}

extension Effect where Failure == NoSuchElementError {
    /// An effect that succeeds with the wrapped value or fails with ``NoSuchElementError``.
    public static func fromOptional(_ value: Success?) -> Effect {
        if let value { succeed(value) } else { fail(NoSuchElementError()) }
    }
}

extension Effect where Success == Void {
    /// An effect that succeeds with `()`.
    public static var void: Effect { succeed(()) }
}

extension Effect where Success == FiberID {
    /// The identifier of the running fiber.
    public static var fiberId: Effect { Effect(unsafe: { fiber in .success(fiber.id) }) }
}

// MARK: - Infallible defaults
//
// Overloads constrained to `Failure == Never` are more specific than the generic versions
// above, so they are chosen when the failure type cannot be inferred from context
// (`let one = Effect.succeed(1)` is an `Effect<Int, Never>`).

extension Effect where Failure == Never {
    /// An infallible effect that succeeds with `value`.
    public static func succeed(_ value: Success) -> Effect {
        Effect(unsafe: { _ in .success(value) })
    }

    /// An infallible effect that runs a synchronous side effect each time it is run.
    public static func sync(_ compute: @escaping @Sendable () -> Success) -> Effect {
        Effect(unsafe: { _ in .success(compute()) })
    }
}

extension Effect where Success == Void, Failure == Never {
    /// An infallible effect that succeeds with `()`.
    public static var void: Effect { succeed(()) }
}

extension Effect where Success == FiberID, Failure == Never {
    /// The identifier of the running fiber.
    public static var fiberId: Effect { Effect(unsafe: { fiber in .success(fiber.id) }) }
}
