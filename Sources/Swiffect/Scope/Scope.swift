import Synchronization

/// A collection of finalizers that run when the scope is closed.
///
/// Resources acquired with ``Effect/acquireRelease(_:release:)``, fibers forked with
/// ``Effect/forkScoped`` and finalizers registered with ``Effect/addFinalizer(_:)`` are attached
/// to the current scope, which lives in the fiber's ``Context`` (`Scope` is its own
/// ``ServiceKey``). ``Effect/scoped`` creates a scope for a region and closes it when the
/// region completes.
///
/// Semantics:
/// - finalizers run in reverse order of registration (LIFO) with the ``FinalizerStrategy/sequential``
///   strategy, or concurrently with ``FinalizerStrategy/parallel``;
/// - closing is idempotent: the first close wins and later closes do nothing;
/// - finalizers always run uninterruptibly and receive the exit the scope was closed with;
/// - adding a finalizer to a closed scope runs it immediately with that exit;
/// - a child scope created with ``fork(strategy:)`` is closed when its parent closes.
///
/// All members are thread-safe.
public final class Scope: Sendable {
    /// How the finalizers of a scope are run when it closes.
    public enum FinalizerStrategy: Sendable, Hashable {
        /// One after another, in reverse order of registration.
        case sequential
        /// All at the same time; closing waits for all of them.
        case parallel
    }

    /// Identifies a registered finalizer so it can be removed again.
    public struct FinalizerKey: Hashable, Sendable {
        let rawValue: UInt64
    }

    /// A finalizer receives the exit the scope was closed with.
    public typealias Finalizer = @Sendable (AnyExit) -> Effect<Void, Never>

    private enum State {
        case open(finalizers: [(key: UInt64, finalizer: Finalizer)], nextKey: UInt64)
        case closed(AnyExit)
    }

    /// The strategy used to run finalizers.
    public let strategy: FinalizerStrategy

    private let state = Mutex<State>(.open(finalizers: [], nextKey: 0))
    private let parentLink = Mutex<(scope: Scope, key: FinalizerKey)?>(nil)

    /// Creates an open scope.
    public init(strategy: FinalizerStrategy = .sequential) {
        self.strategy = strategy
    }

    /// An effect that creates an open scope. The caller is responsible for closing it.
    public static func make(strategy: FinalizerStrategy = .sequential) -> Effect<Scope, Never> {
        .sync { Scope(strategy: strategy) }
    }

    /// Whether the scope has been closed.
    public var isClosed: Bool {
        state.withLock { if case .closed = $0 { true } else { false } }
    }

    /// Registers a finalizer and returns its key, or returns `nil` without registering if the
    /// scope is already closed.
    @discardableResult
    public func unsafeAddFinalizer(_ finalizer: @escaping Finalizer) -> FinalizerKey? {
        state.withLock { state in
            guard case .open(var finalizers, let nextKey) = state else { return nil }
            finalizers.append((nextKey, finalizer))
            state = .open(finalizers: finalizers, nextKey: nextKey + 1)
            return FinalizerKey(rawValue: nextKey)
        }
    }

    /// Removes a finalizer registered with ``unsafeAddFinalizer(_:)``. Does nothing if the
    /// finalizer is unknown or the scope is closed.
    public func unsafeRemoveFinalizer(_ key: FinalizerKey) {
        state.withLock { state in
            guard case .open(var finalizers, let nextKey) = state else { return }
            finalizers.removeAll { $0.key == key.rawValue }
            state = .open(finalizers: finalizers, nextKey: nextKey)
        }
    }

    /// Registers a finalizer. If the scope is already closed the finalizer runs immediately
    /// (uninterruptibly) with the exit the scope was closed with.
    public func addFinalizer(_ finalizer: @escaping Finalizer) -> Effect<Void, Never> {
        Effect<Void, Never>(unsafe: { fiber in
            if self.unsafeAddFinalizer(finalizer) != nil { return .success(()) }
            guard let exit = self.closedExit else { return .success(()) }
            return await fiber.runUninterruptibly(finalizer(exit))
        })
    }

    /// Registers a finalizer that does not need the exit.
    public func addFinalizer(_ finalizer: Effect<Void, Never>) -> Effect<Void, Never> {
        addFinalizer { _ in finalizer }
    }

    /// Closes the scope with `exit`, running all finalizers uninterruptibly.
    ///
    /// Only the first close runs the finalizers; later calls complete immediately. If
    /// finalizers die, the returned effect fails with all of their defects.
    public func close(_ exit: AnyExit) -> Effect<Void, Never> {
        Effect<Void, Never>(unsafe: { fiber in
            guard let finalizers = self.unsafeBeginClose(exit) else { return .success(()) }
            return await fiber.runUninterruptibly(Self.run(finalizers, exit: exit, strategy: self.strategy))
        })
    }

    /// Creates a child scope that is closed when this scope closes. Closing the child first
    /// detaches it from this scope. Forking a closed scope returns a closed child.
    public func fork(strategy: FinalizerStrategy = .sequential) -> Effect<Scope, Never> {
        .sync { self.unsafeFork(strategy: strategy) }
    }

    /// Synchronous variant of ``fork(strategy:)``.
    public func unsafeFork(strategy: FinalizerStrategy = .sequential) -> Scope {
        let child = Scope(strategy: strategy)
        if let key = unsafeAddFinalizer({ exit in child.close(exit) }) {
            child.parentLink.withLock { $0 = (self, key) }
        } else if let exit = closedExit {
            child.state.withLock { $0 = .closed(exit) }
        }
        return child
    }

    private var closedExit: AnyExit? {
        state.withLock { if case .closed(let exit) = $0 { exit } else { nil } }
    }

    /// Marks the scope closed and returns its finalizers in execution (LIFO) order, or `nil` if
    /// it was already closed.
    private func unsafeBeginClose(_ exit: AnyExit) -> [Finalizer]? {
        let finalizers: [Finalizer]? = state.withLock { state in
            guard case .open(let finalizers, _) = state else { return nil }
            state = .closed(exit)
            return finalizers.reversed().map(\.finalizer)
        }
        if finalizers != nil, let link = parentLink.withLock({ $0.take() }) {
            link.scope.unsafeRemoveFinalizer(link.key)
        }
        return finalizers
    }

    private static func run(_ finalizers: [Finalizer], exit: AnyExit, strategy: FinalizerStrategy) -> Effect<Void, Never> {
        Effect<Void, Never>(unsafe: { fiber in
            var cause = Cause<Never>.empty
            switch strategy {
            case .sequential:
                for finalizer in finalizers {
                    if case .failure(let failure) = await finalizer(exit).unsafeRun(in: fiber) {
                        cause = cause + failure
                    }
                }
            case .parallel:
                let fibers = finalizers.map { finalizer in
                    Effect<Void, Never>.unsafeForkDetached(finalizer(exit), context: fiber.context, interruptible: false)
                }
                for child in fibers {
                    if case .failure(let failure) = await child.exit { cause = cause + failure }
                }
            }
            return cause.isEmpty ? .success(()) : .failure(cause)
        })
    }
}

extension Scope: ServiceKey {
    /// A scope is stored in the context under its own type.
    public typealias Value = Scope
}
