extension Fiber {
    /// Waits for all fibers to complete and returns their exits in order.
    public static func awaitAll(_ fibers: [Fiber]) -> Effect<[Exit<Success, Failure>], Never> {
        Effect<[Exit<Success, Failure>], Never>(unsafe: { fiber in
            var exits: [Exit<Success, Failure>] = []
            exits.reserveCapacity(fibers.count)
            for child in fibers {
                switch await child.await.unsafeRun(in: fiber) {
                case .success(let exit): exits.append(exit)
                case .failure(let cause): return .failure(cause)
                }
            }
            return .success(exits)
        })
    }

    /// Joins all fibers in order and returns their values. Fails with the first failure
    /// encountered (in order), without interrupting the remaining fibers.
    public static func joinAll(_ fibers: [Fiber]) -> Effect<[Success], Failure> {
        Effect<[Success], Failure>(unsafe: { fiber in
            var values: [Success] = []
            values.reserveCapacity(fibers.count)
            for child in fibers {
                switch await child.join.unsafeRun(in: fiber) {
                case .success(let value): values.append(value)
                case .failure(let cause): return .failure(cause)
                }
            }
            return .success(values)
        })
    }

    /// Interrupts all fibers, then waits for all of them to complete.
    public static func interruptAll(_ fibers: [Fiber]) -> Effect<Void, Never> {
        Effect<Void, Never>(unsafe: { fiber in
            for child in fibers { child.core.interrupt(by: fiber.id) }
            return await awaitAll(fibers).asVoid.unsafeRun(in: fiber)
        })
    }
}

extension Effect where Success == FiberRuntime {
    /// The running fiber, as seen from inside an effect.
    public static var currentFiber: Effect {
        Effect(unsafe: { fiber in .success(fiber) })
    }
}

extension Effect where Success == FiberRuntime, Failure == Never {
    /// The running fiber, as seen from inside an effect.
    public static var currentFiber: Effect {
        Effect(unsafe: { fiber in .success(fiber) })
    }
}
