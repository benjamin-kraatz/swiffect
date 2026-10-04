/// The binder passed to the body of ``Effect/gen(_:)``. Calling it runs an effect on the
/// current fiber and returns its value.
///
/// ```swift
/// let program: Effect<Int, AppError> = .gen { bind in
///     let a = try await bind(loadA())          // Effect<Int, AppError>
///     let b = try await bind(Effect.succeed(2)) // infallible effects work too
///     return a + b
/// }
/// ```
///
/// When the bound effect fails with a plain typed failure, the binder throws that `Failure`
/// value, so ordinary `do`/`catch` can handle it. Any other failure (defects, interruptions,
/// several reasons) is thrown as a ``FiberFailure`` that ``Effect/gen(_:)`` turns back into
/// the original cause. Catching and ignoring a ``FiberFailure`` caused by interruption does not
/// stop the interruption: the next bound effect fails again.
///
/// The binder belongs to the fiber running the `gen` body; do not use it from other tasks.
public struct Bind<Failure: Error>: Sendable {
    /// The fiber running the `gen` body, for writing custom primitives inline.
    public let fiber: FiberRuntime

    /// The context of the running fiber.
    public var context: Context { fiber.context }

    /// Runs `effect` on the current fiber and returns its value, or throws its failure.
    public func callAsFunction<A: Sendable>(_ effect: Effect<A, Failure>) async throws -> A {
        switch await effect.unsafeRun(in: fiber) {
        case .success(let value):
            return value
        case .failure(let cause):
            if cause.hasFailsOnly, cause.reasons.count == 1, let failure = cause.firstFailure {
                throw failure
            }
            throw FiberFailure(cause)
        }
    }

    /// Runs an infallible `effect` on the current fiber and returns its value. Throws only if
    /// the effect dies or is interrupted.
    @_disfavoredOverload
    public func callAsFunction<A: Sendable>(_ effect: Effect<A, Never>) async throws -> A {
        switch await effect.unsafeRun(in: fiber) {
        case .success(let value): return value
        case .failure(let cause): throw FiberFailure(cause.widen(to: Failure.self))
        }
    }
}

extension Effect {
    /// Builds an effect from imperative code (Effect's `gen`/do-notation).
    ///
    /// Inside `body`, run effects with the ``Bind`` binder: `try await bind(effect)`. The
    /// outcome of `body` maps onto the effect as follows:
    /// - returning a value succeeds with it;
    /// - a failure propagated from a bound effect keeps its exact cause (defects and
    ///   interruptions included);
    /// - throwing a `Failure` value fails with it;
    /// - throwing any other error is a defect.
    ///
    /// ```swift
    /// func transfer(_ amount: Int) -> Effect<Receipt, BankError> {
    ///     .gen { bind in
    ///         let balance = try await bind(account.balance)
    ///         guard balance >= amount else { throw BankError.insufficientFunds }
    ///         return try await bind(account.withdraw(amount))
    ///     }
    /// }
    /// ```
    ///
    /// The body runs on the fiber's task. Plain Swift `async` calls made directly in the body
    /// are not interruptible; wrap them in an effect (`Effect { await ... }`) and bind it to
    /// make them so.
    public static func gen(_ body: @escaping @Sendable (_ bind: Bind<Failure>) async throws -> Success) -> Effect {
        Effect(unsafe: { fiber in
            do {
                return .success(try await body(Bind(fiber: fiber)))
            } catch let failure as FiberFailure {
                if let cause = failure.typed(as: Failure.self) { return .failure(cause) }
                return .failure(Cause(reasons: failure.cause.reasons.map { reason in
                    switch reason {
                    case .fail(let error): (error as? Failure).map { .fail($0) } ?? .die(error)
                    case .die(let defect): .die(defect)
                    case .interrupt(let id): .interrupt(id)
                    }
                }))
            } catch let failure as Failure {
                return .fail(failure)
            } catch {
                return .die(error)
            }
        })
    }
}
