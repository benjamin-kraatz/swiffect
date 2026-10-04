import Synchronization

extension Effect {
    /// Completes an ``Effect/callback(_:)`` and registers its interruption cleanup.
    ///
    /// Call it like a function to resume the waiting fiber with an effect, e.g.
    /// `resume(.succeed(value))` or `resume(.fail(error))`. Only the first call counts; it may
    /// happen synchronously inside `register` or later on any thread.
    public struct Resume: Sendable {
        let complete: @Sendable (Effect) -> Void
        let cleanup: CallbackCleanup

        /// Resumes the waiting fiber, which continues by running `effect`.
        public func callAsFunction(_ effect: Effect) {
            complete(effect)
        }

        /// Registers an effect that runs (uninterruptibly) if the fiber is interrupted while
        /// waiting, e.g. to cancel the underlying operation. Call it synchronously inside
        /// `register`; a later registration replaces an earlier one.
        public func onInterrupt(_ cleanup: Effect<Void, Never>) {
            self.cleanup.set(cleanup)
        }

        /// Registers a synchronous action that runs if the fiber is interrupted while waiting.
        public func onInterrupt(_ action: @escaping @Sendable () -> Void) {
            cleanup.set(.sync(action))
        }
    }

    /// Creates an effect from a callback-based API.
    ///
    /// `register` is called each time the effect runs. It receives a ``Resume`` that completes
    /// the effect. While waiting the fiber is suspended; if it is interrupted (and
    /// interruptible) it wakes up immediately with the interruption, runs the cleanup
    /// registered with ``Resume/onInterrupt(_:)`` uninterruptibly, and
    /// ignores any later `resume`. In an uninterruptible region the fiber waits for `resume`.
    ///
    /// This is the primitive for integrating callback APIs and for building synchronization
    /// primitives (deferreds, queues, semaphores, clocks).
    ///
    /// ```swift
    /// let delayed = Effect<Int, Never>.callback { resume in
    ///     let item = DispatchWorkItem { resume(.succeed(42)) }
    ///     DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: item)
    ///     resume.onInterrupt { item.cancel() }
    /// }
    /// ```
    public static func callback(_ register: @escaping @Sendable (_ resume: Resume) -> Void) -> Effect {
        Effect(unsafe: { fiber in
            let cleanup = CallbackCleanup()
            let resumed: Effect? = await fiber.suspend { complete in
                register(Resume(complete: complete, cleanup: cleanup))
            }
            if let resumed { return await resumed.unsafeRun(in: fiber) }
            if let effect = cleanup.effect { _ = await fiber.runUninterruptibly(effect) }
            return fiber.interruptedExit()
        })
    }
}

/// Holds the interruption cleanup registered through ``Effect/Resume``.
final class CallbackCleanup: Sendable {
    private let storage = Mutex<Effect<Void, Never>?>(nil)

    func set(_ effect: Effect<Void, Never>) {
        storage.withLock { $0 = effect }
    }

    var effect: Effect<Void, Never>? {
        storage.withLock { $0 }
    }
}
