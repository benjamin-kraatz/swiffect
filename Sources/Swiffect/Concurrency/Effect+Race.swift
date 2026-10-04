extension Effect {
    /// Runs all effects concurrently and returns the first success. As soon as one succeeds
    /// the others are interrupted and awaited. If all fail, the result fails with all of their
    /// causes combined.
    ///
    /// Dies if `effects` is empty.
    public static func raceAll(_ effects: [Effect]) -> Effect {
        race(effects, firstCompletionWins: false)
    }

    /// Races `self` against `that`: the first success wins and the loser is interrupted and
    /// awaited. If both fail, the result fails with both causes.
    ///
    /// ```swift
    /// let fastest = primary.race(replica)
    /// ```
    public func race(_ that: Effect) -> Effect {
        Effect.raceAll([self, that])
    }

    /// Races `self` against `that`: the first effect to complete, successfully or not, wins
    /// and the other is interrupted and awaited.
    public func raceFirst(_ that: Effect) -> Effect {
        Effect.race([self, that], firstCompletionWins: true)
    }

    private static func race(_ effects: [Effect], firstCompletionWins: Bool) -> Effect {
        Effect(unsafe: { fiber in
            guard !effects.isEmpty else { return .die(RuntimeError("race requires at least one effect")) }
            let group = ChildGroup<Success, Failure>(parent: fiber, inheritInterruptibility: false)
            for (index, effect) in effects.enumerated() { group.fork(effect, index: index) }
            var failures = Cause<Failure>.empty
            for _ in effects.indices {
                guard let (_, exit) = await group.next() else {
                    await group.shutdown()
                    return fiber.interruptedExit()
                }
                switch exit {
                case .failure(let cause) where !firstCompletionWins:
                    failures = failures + cause
                default:
                    await group.shutdown()
                    return exit
                }
            }
            return .failure(failures)
        })
    }
}
