/// How many effects a collection operator may run at the same time.
///
/// ```swift
/// Effect.forEach(urls, concurrency: .bounded(4)) { download($0) }
/// Effect.forEach(urls, concurrency: 4) { download($0) }   // integer literal = .bounded(4)
/// ```
public enum Concurrency: Sendable, Hashable, ExpressibleByIntegerLiteral {
    /// One after another, on the calling fiber (the default).
    case sequential
    /// At most the given number at a time, each on its own fiber. Values below 1 count as 1.
    case bounded(Int)
    /// All at once, each on its own fiber.
    case unbounded

    /// Creates a ``bounded(_:)`` concurrency limit from an integer literal.
    public init(integerLiteral value: Int) {
        self = .bounded(value)
    }

    /// The maximum number of effects running at once.
    var limit: Int {
        switch self {
        case .sequential: 1
        case .bounded(let n): max(1, n)
        case .unbounded: .max
        }
    }

    /// Whether effects run inline on the calling fiber.
    var isSequential: Bool {
        if case .sequential = self { true } else { false }
    }
}
