extension Effect {
    /// Starts the effect on a new child fiber and returns its handle immediately.
    ///
    /// The child receives a snapshot of the parent's context and starts interruptible. Its
    /// lifetime is bounded by the parent (v4 semantics): when the parent's effect completes,
    /// the parent interrupts all children that are still running and waits for them before
    /// publishing its own exit.
    public var forkChild: Effect<Fiber<Success, Failure>, Never> {
        Effect<Fiber<Success, Failure>, Never>(unsafe: { parent in
            let child = FiberCore()
            parent.core.addChild(child)
            child.start(self, context: parent.context)
            return .success(Fiber(core: child))
        })
    }

    /// Starts the effect on a new detached fiber (Effect's `forkDaemon`).
    ///
    /// The fiber receives a snapshot of the parent's context but is not supervised by the
    /// parent: it keeps running after the parent completes, until it finishes or is
    /// interrupted explicitly.
    public var forkDetach: Effect<Fiber<Success, Failure>, Never> {
        Effect<Fiber<Success, Failure>, Never>(unsafe: { parent in
            .success(Self.unsafeForkDetached(self, context: parent.context))
        })
    }

    /// Starts the effect on a new fiber whose lifetime is bound to `scope`: closing the scope
    /// interrupts the fiber and waits for it. If the scope is already closed the fiber is
    /// interrupted immediately.
    public func forkIn(_ scope: Scope) -> Effect<Fiber<Success, Failure>, Never> {
        Effect<Fiber<Success, Failure>, Never>(unsafe: { parent in
            let fiber = Self.unsafeForkDetached(self, context: parent.context)
            let core = fiber.core
            let key = scope.unsafeAddFinalizer { _ in
                Effect<Void, Never>(unsafe: { closing in
                    // A fiber closing the scope it lives in must not wait for itself.
                    if closing.id == core.id { return .success(()) }
                    return await fiber.interrupt.unsafeRun(in: closing)
                })
            }
            if let key {
                core.observe { _ in scope.unsafeRemoveFinalizer(key) }
            } else {
                core.interrupt(by: parent.id)
            }
            return .success(fiber)
        })
    }

    /// Starts the effect on a new fiber bound to the current scope (see ``forkIn(_:)``).
    /// Dies with ``MissingServiceError`` if no scope is available.
    public var forkScoped: Effect<Fiber<Success, Failure>, Never> {
        Effect<Scope, Never>.scope.flatMap { scope in self.forkIn(scope) }
    }

    /// Creates and starts a detached fiber. Low-level building block for fork variants.
    static func unsafeForkDetached(_ effect: Effect, context: Context, interruptible: Bool = true) -> Fiber<Success, Failure> {
        let core = FiberCore(interruptible: interruptible)
        core.start(effect, context: context)
        return Fiber(core: core)
    }
}
