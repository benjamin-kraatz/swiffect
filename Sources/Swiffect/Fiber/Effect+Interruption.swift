// Interruption model
//
// Each fiber has a sticky, accumulating interrupt cause and an interruptible flag. An interrupt
// request records the interruptor and, if the fiber is suspended interruptibly (sleeping,
// waiting on a callback or another fiber), wakes it immediately. A running fiber notices the
// request at the next operator boundary. Regions toggle the flag; when a region restores
// interruptibility and an interrupt is pending, its result is replaced by the interrupt cause.

extension Effect {
    /// An effect that interrupts the running fiber: it fails with an interruption attributed
    /// to the current fiber.
    public static var interrupt: Effect {
        Effect(unsafe: { fiber in .interrupt(fiber.id) })
    }

    /// Runs the effect with interruption disabled.
    ///
    /// Interrupt requests arriving meanwhile are recorded; if the surrounding region is
    /// interruptible the result is replaced by the interrupt cause as soon as this region
    /// ends.
    public var uninterruptible: Effect {
        Effect(unsafe: { fiber in
            let core = fiber.core
            guard core.isInterruptible else { return await self.unsafeRun(in: fiber) }
            core.setInterruptible(false)
            let exit = await self.unsafeRun(in: fiber)
            core.setInterruptible(true)
            return core.isInterrupted ? fiber.interruptedExit() : exit
        })
    }

    /// Runs the effect with interruption enabled, even inside an uninterruptible region. A
    /// pending interruption takes effect immediately.
    public var interruptible: Effect {
        Effect(unsafe: { fiber in
            let core = fiber.core
            guard !core.isInterruptible else { return await self.unsafeRun(in: fiber) }
            core.setInterruptible(true)
            let exit = await self.unsafeRun(in: fiber)
            core.setInterruptible(false)
            return exit
        })
    }

    /// Runs the effect built by `body` uninterruptibly. The `restore` function passed to
    /// `body` brings back the interruptibility that was in effect outside the region.
    ///
    /// This is the building block for safe resource handling: acquisition and release are
    /// protected while the use phase stays interruptible.
    ///
    /// ```swift
    /// let safe = Effect<Int, MyError>.uninterruptibleMask { restore in
    ///     acquire.flatMap { resource in
    ///         restore(use(resource)).onExit { _ in release(resource) }
    ///     }
    /// }
    /// ```
    public static func uninterruptibleMask(
        _ body: @escaping @Sendable (_ restore: InterruptibilityRestorer) -> Effect
    ) -> Effect {
        Effect(unsafe: { fiber in
            let core = fiber.core
            guard core.isInterruptible else {
                return await body(InterruptibilityRestorer(mode: .keep)).unsafeRun(in: fiber)
            }
            core.setInterruptible(false)
            let exit = await body(InterruptibilityRestorer(mode: .interruptible)).unsafeRun(in: fiber)
            core.setInterruptible(true)
            return core.isInterrupted ? fiber.interruptedExit() : exit
        })
    }

    /// Runs the effect built by `body` interruptibly. The `restore` function passed to `body`
    /// brings back the interruptibility that was in effect outside the region.
    public static func interruptibleMask(
        _ body: @escaping @Sendable (_ restore: InterruptibilityRestorer) -> Effect
    ) -> Effect {
        Effect(unsafe: { fiber in
            let core = fiber.core
            guard !core.isInterruptible else {
                return await body(InterruptibilityRestorer(mode: .keep)).unsafeRun(in: fiber)
            }
            core.setInterruptible(true)
            let exit = await body(InterruptibilityRestorer(mode: .uninterruptible)).unsafeRun(in: fiber)
            core.setInterruptible(false)
            return exit
        })
    }
}

/// Restores the interruptibility that surrounded an ``Effect/uninterruptibleMask(_:)`` or
/// ``Effect/interruptibleMask(_:)`` region. Call it like a function: `restore(effect)`.
public struct InterruptibilityRestorer: Sendable {
    enum Mode: Sendable {
        case keep
        case interruptible
        case uninterruptible
    }

    let mode: Mode

    /// Returns `effect` running with the interruptibility of the enclosing region.
    public func callAsFunction<A: Sendable, E: Error>(_ effect: Effect<A, E>) -> Effect<A, E> {
        switch mode {
        case .keep: effect
        case .interruptible: effect.interruptible
        case .uninterruptible: effect.uninterruptible
        }
    }
}
