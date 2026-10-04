extension Effect {
    /// Creates an effect from a Swift `async` operation (Effect's `promise`).
    ///
    /// The operation runs in a child Swift `Task` each time the effect runs. Interrupting the
    /// fiber cancels that task and resumes the fiber right away, without waiting for the task
    /// to observe its cancellation. In an uninterruptible region the operation runs inline.
    ///
    /// ```swift
    /// let page = Effect { await cache.page(3) }   // Effect<Page, Never>
    /// ```
    public init(_ operation: @escaping @Sendable () async -> Success) where Failure == Never {
        self = Effect.bridge { .success(await operation()) }
    }

    /// Creates an effect from a throwing Swift `async` operation (Effect's `tryPromise`). The
    /// thrown error becomes the typed failure.
    ///
    /// With typed throws the failure type is inferred from the closure; an untyped closure
    /// yields `Failure == any Error`. Interruption cancels the underlying task, as for the
    /// non-throwing initializer.
    ///
    /// ```swift
    /// let data = Effect { try await URLSession.shared.data(from: url).0 }  // Effect<Data, any Error>
    /// ```
    public init(_ operation: @escaping @Sendable () async throws(Failure) -> Success) {
        self = Effect.bridge {
            do throws(Failure) {
                return .success(try await operation())
            } catch {
                return .fail(error)
            }
        }
    }

    /// Creates an effect from a throwing Swift `async` operation, mapping the thrown error into
    /// the typed failure with `mapError`.
    public init<E: Error>(
        _ operation: @escaping @Sendable () async throws(E) -> Success,
        catch mapError: @escaping @Sendable (E) -> Failure
    ) {
        self = Effect.bridge {
            do throws(E) {
                return .success(try await operation())
            } catch {
                return .fail(mapError(error))
            }
        }
    }

    private static func bridge(_ operation: @escaping @Sendable () async -> Exit<Success, Failure>) -> Effect {
        Effect(unsafe: { fiber in
            guard fiber.isInterruptible else { return await operation() }
            let task: Effect = callback { resume in
                let task = Task { resume(.fromExit(await operation())) }
                return .sync { task.cancel() }
            }
            return await task.unsafeRun(in: fiber)
        })
    }

    /// Creates an effect from a callback-based API.
    ///
    /// `register` is called when the effect runs and receives `resume`, which completes the
    /// effect with the given effect (only the first call counts; it may happen synchronously
    /// or later on any thread). If the fiber is interrupted while waiting it wakes up
    /// immediately with the interruption, and the effect returned by `register` (if any) runs
    /// uninterruptibly to clean up.
    ///
    /// ```swift
    /// let delayed = Effect<Int, Never>.callback { resume in
    ///     let item = DispatchWorkItem { resume(.succeed(42)) }
    ///     DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: item)
    ///     return .sync { item.cancel() }
    /// }
    /// ```
    @_disfavoredOverload
    public static func callback(
        _ register: @escaping @Sendable (_ resume: @escaping @Sendable (Effect) -> Void) -> Effect<Void, Never>?
    ) -> Effect {
        Effect(unsafe: { fiber in
            var cleanup: Effect<Void, Never>?
            let resumed: Effect? = await fiber.suspend { resume in
                cleanup = register(resume)
            }
            if let resumed { return await resumed.unsafeRun(in: fiber) }
            if let cleanup { _ = await fiber.runUninterruptibly(cleanup) }
            return fiber.interruptedExit()
        })
    }

    /// Creates an effect from a callback-based API that needs no cleanup on interruption.
    ///
    /// See the cleanup-returning overload of `callback(_:)` for the semantics of `resume`.
    public static func callback(
        _ register: @escaping @Sendable (_ resume: @escaping @Sendable (Effect) -> Void) -> Void
    ) -> Effect {
        callback { resume -> Effect<Void, Never>? in
            register(resume)
            return nil
        }
    }

    /// An effect that never completes. It can only end through interruption.
    public static var never: Effect {
        callback { (_: @escaping @Sendable (Effect) -> Void) -> Effect<Void, Never>? in nil }
    }
}

extension Effect where Success == Void {
    /// An effect that yields the current thread so other tasks can run.
    public static var yieldNow: Effect {
        Effect(unsafe: { _ in
            await Task.yield()
            return .success(())
        })
    }
}

extension Effect where Success == Void, Failure == Never {
    /// An infallible effect that yields the current thread so other tasks can run.
    public static var yieldNow: Effect {
        Effect(unsafe: { _ in
            await Task.yield()
            return .success(())
        })
    }
}

extension Effect where Success == Never, Failure == Never {
    /// An infallible effect that never completes. It can only end through interruption.
    public static var never: Effect {
        callback { (_: @escaping @Sendable (Effect) -> Void) -> Effect<Void, Never>? in nil }
    }
}
