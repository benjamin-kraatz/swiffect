extension Effect {
    /// Runs `transform` for every element without stopping at failures, and collects the
    /// results in order.
    ///
    /// If any element fails, the result fails with a cause containing every typed failure (in
    /// element order), so `catchCause { $0.failures }` sees all of them while `catchAll` sees
    /// the first. Defects and interruptions of elements are included in that cause as well.
    public static func validate<S: Sequence, B: Sendable>(
        _ elements: S,
        concurrency: Concurrency = .sequential,
        _ transform: @escaping @Sendable (S.Element) -> Effect<B, Failure>
    ) -> Effect where Success == [B], S.Element: Sendable {
        let items = Array(elements)
        return Effect(unsafe: { fiber in
            let exits = await fiber.runAll(count: items.count, concurrency: concurrency) { transform(items[$0]).exit }
            switch exits {
            case .failure(let cause):
                return .failure(cause.widen())
            case .success(let exits):
                var values: [B] = []
                var cause = Cause<Failure>.empty
                for exit in exits {
                    switch exit {
                    case .success(let value): values.append(value)
                    case .failure(let failure): cause = cause + failure
                    }
                }
                return cause.isEmpty ? .success(values) : .failure(cause)
            }
        })
    }

    /// Folds the elements sequentially with an effectful `combine`, starting from `initial`.
    public static func reduce<S: Sequence>(
        _ elements: S,
        _ initial: Success,
        _ combine: @escaping @Sendable (Success, S.Element) -> Effect
    ) -> Effect where S.Element: Sendable {
        let items = Array(elements)
        return Effect(unsafe: { fiber in
            var accumulator = initial
            for item in items {
                switch await combine(accumulator, item).unsafeRun(in: fiber) {
                case .success(let value): accumulator = value
                case .failure(let cause): return .failure(cause)
                }
            }
            return .success(accumulator)
        })
    }

    /// Keeps the elements for which the effectful `predicate` succeeds with `true`, in order.
    public static func filter<S: Sequence>(
        _ elements: S,
        concurrency: Concurrency = .sequential,
        _ predicate: @escaping @Sendable (S.Element) -> Effect<Bool, Failure>
    ) -> Effect where Success == [S.Element], S.Element: Sendable {
        Effect<[S.Element?], Failure>.forEach(elements, concurrency: concurrency) { item in
            predicate(item).map { $0 ? item : nil }
        }.map { $0.compactMap { $0 } }
    }

    /// Returns the first element, in order, for which the effectful `predicate` succeeds with
    /// `true`, or `nil`. Elements after the match are not tested.
    public static func findFirst<S: Sequence>(
        _ elements: S,
        _ predicate: @escaping @Sendable (S.Element) -> Effect<Bool, Failure>
    ) -> Effect where Success == S.Element?, S.Element: Sendable {
        let items = Array(elements)
        return Effect(unsafe: { fiber in
            for item in items {
                switch await predicate(item).unsafeRun(in: fiber) {
                case .success(true): return .success(item)
                case .success(false): continue
                case .failure(let cause): return .failure(cause)
                }
            }
            return .success(nil)
        })
    }
}

extension Effect {
    /// Runs the effect `count` times and collects the results.
    public func replicateEffect(_ count: Int, concurrency: Concurrency = .sequential) -> Effect<[Success], Failure> {
        Effect<[Success], Failure>.all(replicate(count), concurrency: concurrency)
    }
}

extension Effect where Failure == Never {
    /// Runs `transform` for every element and separates typed failures from successes,
    /// preserving element order within each list. Defects and interruptions propagate.
    public static func partition<S: Sequence, B: Sendable, E: Error>(
        _ elements: S,
        concurrency: Concurrency = .sequential,
        _ transform: @escaping @Sendable (S.Element) -> Effect<B, E>
    ) -> Effect where Success == (failures: [E], successes: [B]), S.Element: Sendable {
        Effect<[Result<B, E>], Never>.forEach(elements, concurrency: concurrency) { transform($0).result }
            .map { results in
                var failures: [E] = []
                var successes: [B] = []
                for result in results {
                    switch result {
                    case .success(let value): successes.append(value)
                    case .failure(let error): failures.append(error)
                    }
                }
                return (failures, successes)
            }
    }
}
