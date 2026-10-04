extension FiberRuntime {
    /// Runs `count` effects built lazily by `make`, with v4 fail-fast semantics, and returns
    /// their values by index.
    ///
    /// - Sequential: effects run inline on this fiber, stopping at the first failure.
    /// - Concurrent: effects run on separate fibers (inheriting this fiber's
    ///   interruptibility), at most `concurrency.limit` at a time. On the first failure no new
    ///   effects start, in-flight ones are interrupted and awaited, and the result fails with
    ///   the first cause plus any non-interruption causes of the siblings. If this fiber is
    ///   interrupted, all children are interrupted and awaited before returning.
    func runAll<A: Sendable, E: Error>(
        count: Int,
        concurrency: Concurrency,
        _ make: (Int) -> Effect<A, E>
    ) async -> Exit<[A], E> {
        if concurrency.isSequential || count <= 1 {
            var values: [A] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                switch await make(index).unsafeRun(in: self) {
                case .success(let value): values.append(value)
                case .failure(let cause): return .failure(cause)
                }
            }
            return .success(values)
        }

        let group = ChildGroup<A, E>(parent: self, inheritInterruptibility: true)
        let limit = concurrency.limit
        var values = [A?](repeating: nil, count: count)
        var nextIndex = 0
        var running = 0
        var failure: Cause<E>?

        while true {
            while failure == nil, running < limit, nextIndex < count {
                group.fork(make(nextIndex), index: nextIndex)
                nextIndex += 1
                running += 1
            }
            if running == 0 { break }
            guard let (index, exit) = await group.next() else {
                await group.shutdown()
                return interruptedExit()
            }
            running -= 1
            switch exit {
            case .success(let value):
                values[index] = value
            case .failure(let cause):
                if let first = failure {
                    let extra = Cause<E>(reasons: cause.reasons.filter {
                        if case .interrupt = $0 { false } else { true }
                    })
                    failure = first + extra
                } else {
                    failure = cause
                    group.interruptAll()
                }
            }
        }
        if let failure { return .failure(failure) }
        return .success(values.map { $0! })
    }
}
