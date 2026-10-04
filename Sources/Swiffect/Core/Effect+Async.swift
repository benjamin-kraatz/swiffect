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
                resume.onInterrupt { task.cancel() }
            }
            return await task.unsafeRun(in: fiber)
        })
    }

    /// An effect that never completes. It can only end through interruption.
    public static var never: Effect {
        callback { _ in }
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
        callback { _ in }
    }
}
