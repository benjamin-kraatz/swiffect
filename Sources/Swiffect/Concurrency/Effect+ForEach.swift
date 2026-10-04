import Synchronization

extension Effect {
    /// Runs `transform` for every element and collects the results in order.
    ///
    /// With ``Concurrency/sequential`` (the default) the effects run one after another on the
    /// calling fiber. Otherwise each runs on its own fiber, bounded by `concurrency`. Failure
    /// is fail-fast: no new effects start, in-flight ones are interrupted and awaited, and the
    /// result fails with the first failure's cause.
    ///
    /// ```swift
    /// let users = Effect.forEach(ids, concurrency: .bounded(8)) { id in fetchUser(id) }
    /// ```
    public static func forEach<S: Sequence, B: Sendable>(
        _ elements: S,
        concurrency: Concurrency = .sequential,
        _ transform: @escaping @Sendable (S.Element) -> Effect<B, Failure>
    ) -> Effect where Success == [B], S.Element: Sendable {
        let items = Array(elements)
        return Effect(unsafe: { fiber in
            await fiber.runAll(count: items.count, concurrency: concurrency) { transform(items[$0]) }
        })
    }

    /// Runs all effects and collects their results in order. See
    /// ``forEach(_:concurrency:_:)`` for the concurrency and failure semantics.
    public static func all<A: Sendable>(
        _ effects: [Effect<A, Failure>],
        concurrency: Concurrency = .sequential
    ) -> Effect where Success == [A] {
        Effect(unsafe: { fiber in
            await fiber.runAll(count: effects.count, concurrency: concurrency) { effects[$0] }
        })
    }

    /// Runs a fixed list of differently typed effects and collects their results in a tuple.
    ///
    /// ```swift
    /// let (user, posts) = try await Effect.all(fetchUser(1), fetchPosts(1), concurrency: .unbounded).run()
    /// ```
    public static func all<each A: Sendable>(
        _ effects: repeat Effect<each A, Failure>,
        concurrency: Concurrency = .sequential
    ) -> Effect<(repeat each A), Failure> where Success == (repeat each A) {
        Effect<(repeat each A), Failure>(unsafe: { fiber in
            let slots = (repeat Slot<each A>())
            var jobs: [Effect<Void, Failure>] = []
            repeat jobs.append((each effects).map { (each slots).set($0) })
            if case .failure(let cause) = await fiber.runAll(count: jobs.count, concurrency: concurrency, { jobs[$0] }) {
                return .failure(cause)
            }
            return .success((repeat (each slots).value))
        })
    }

    /// Combines two effects into a tuple of their results, sequentially by default or
    /// concurrently (fail-fast) when `concurrent` is `true`.
    public func zip<B: Sendable>(_ that: Effect<B, Failure>, concurrent: Bool = false) -> Effect<(Success, B), Failure> {
        Effect<(Success, B), Failure>.all(self, that, concurrency: concurrent ? .unbounded : .sequential)
    }

    /// Combines two effects with `combine`, sequentially by default or concurrently
    /// (fail-fast) when `concurrent` is `true`.
    public func zipWith<B: Sendable, C: Sendable>(
        _ that: Effect<B, Failure>,
        concurrent: Bool = false,
        _ combine: @escaping @Sendable (Success, B) -> C
    ) -> Effect<C, Failure> {
        zip(that, concurrent: concurrent).map { combine($0.0, $0.1) }
    }
}

extension Effect where Success == Void {
    /// Like ``forEach(_:concurrency:_:)`` but discards the results.
    public static func forEachDiscarding<S: Sequence, B: Sendable>(
        _ elements: S,
        concurrency: Concurrency = .sequential,
        _ transform: @escaping @Sendable (S.Element) -> Effect<B, Failure>
    ) -> Effect where S.Element: Sendable {
        let items = Array(elements)
        return Effect(unsafe: { fiber in
            await fiber.runAll(count: items.count, concurrency: concurrency) { transform(items[$0]).asVoid }.map { _ in () }
        })
    }

    /// Like the array overload of `all(_:concurrency:)` but discards the results.
    public static func allDiscarding<A: Sendable>(
        _ effects: [Effect<A, Failure>],
        concurrency: Concurrency = .sequential
    ) -> Effect {
        Effect(unsafe: { fiber in
            await fiber.runAll(count: effects.count, concurrency: concurrency) { effects[$0].asVoid }.map { _ in () }
        })
    }
}

/// A write-once cell used to collect heterogeneous results from concurrent fibers.
final class Slot<T: Sendable>: Sendable {
    private let storage = Mutex<T?>(nil)

    func set(_ value: T) {
        storage.withLock { $0 = value }
    }

    var value: T {
        storage.withLock { $0! }
    }
}
