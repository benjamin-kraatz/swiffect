import Synchronization

/// A process-unique identifier of a fiber.
///
/// Identifiers are allocated from a monotonically increasing counter when a fiber is created, so
/// a larger identifier always belongs to a fiber created later. They appear in interruption
/// reasons (``Cause/Reason/interrupt(_:)``) to record *who* interrupted a fiber.
public struct FiberID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The numeric value of the identifier.
    public let rawValue: UInt64

    /// Creates an identifier from a raw value.
    ///
    /// Prefer letting the runtime allocate identifiers; this initializer exists for tests and
    /// for reconstructing identifiers from logs.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Allocates a fresh identifier.
    static func next() -> FiberID {
        FiberID(rawValue: fiberIDCounter.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    /// Orders identifiers by creation order.
    public static func < (lhs: FiberID, rhs: FiberID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A short representation such as `#42`.
    public var description: String { "#\(rawValue)" }
}

private let fiberIDCounter = Atomic<UInt64>(0)
