extension Effect {
    /// Runs the effect in a fresh scope that is closed, with the effect's exit, as soon as the
    /// effect completes. Resources and scoped fibers acquired inside are released at that
    /// point.
    ///
    /// ```swift
    /// let contents = Effect.acquireRelease(open(path), release: { file, _ in close(file) })
    ///     .flatMap { file in read(file) }
    ///     .scoped
    /// ```
    public var scoped: Effect {
        Effect.scopedWith { scope in self.provideService(Scope.self, scope) }
    }

    /// Creates a fresh scope, passes it to `body` and closes it with the exit of the returned
    /// effect. Unlike ``scoped`` the scope is not installed in the context.
    public static func scopedWith(_ body: @escaping @Sendable (Scope) -> Effect) -> Effect {
        Effect.suspend {
            let scope = Scope()
            return body(scope).onExit { exit in scope.close(exit.erased) }
        }
    }

    /// Acquires a resource uninterruptibly and registers `release` in the current scope.
    ///
    /// `release` runs when the scope closes and receives the scope's exit. Dies with
    /// ``MissingServiceError`` if no scope is available.
    ///
    /// ```swift
    /// let connection = Effect.acquireRelease(pool.connect) { conn, _ in pool.release(conn) }
    /// ```
    public static func acquireRelease(
        _ acquire: Effect,
        release: @escaping @Sendable (Success, AnyExit) -> Effect<Void, Never>
    ) -> Effect {
        Effect<Scope, Failure>.scope.flatMap { scope in
            acquire.tap { resource in
                scope.addFinalizer { exit in release(resource, exit) }
            }
        }.uninterruptible
    }

    /// Acquires a resource, uses it and releases it, regardless of how `use` completes.
    ///
    /// Acquisition and release are uninterruptible; `use` keeps the interruptibility of the
    /// surrounding region. If `release` dies its defects are added to the result.
    public static func acquireUseRelease<Resource: Sendable>(
        _ acquire: Effect<Resource, Failure>,
        use: @escaping @Sendable (Resource) -> Effect,
        release: @escaping @Sendable (Resource, Exit<Success, Failure>) -> Effect<Void, Never>
    ) -> Effect {
        Effect.uninterruptibleMask { restore in
            acquire.flatMap { resource in
                restore(use(resource)).onExit { exit in release(resource, exit) }
            }
        }
    }
}

extension Effect where Success == Scope {
    /// The current scope. Dies with ``MissingServiceError`` if no scope is available.
    public static var scope: Effect { service(Scope.self) }
}

extension Effect where Success == Scope, Failure == Never {
    /// The current scope. Dies with ``MissingServiceError`` if no scope is available.
    public static var scope: Effect { service(Scope.self) }
}

extension Effect where Success == Void {
    /// Registers a finalizer in the current scope. It runs when the scope closes and receives
    /// the scope's exit. Dies with ``MissingServiceError`` if no scope is available.
    public static func addFinalizer(_ finalizer: @escaping Scope.Finalizer) -> Effect {
        Effect<Scope, Failure>.scope.flatMap { scope in scope.addFinalizer(finalizer) }
    }
}

extension Effect where Success == Void, Failure == Never {
    /// Registers a finalizer in the current scope (infallible default overload).
    public static func addFinalizer(_ finalizer: @escaping Scope.Finalizer) -> Effect {
        Effect<Scope, Never>.scope.flatMap { scope in scope.addFinalizer(finalizer) }
    }
}
