/// The full story of why an effect did not succeed.
///
/// A cause is a flat list of ``Reason``s (the Effect v4 model): expected, typed failures
/// (``Reason/fail(_:)``), unexpected defects (``Reason/die(_:)``) and interruptions
/// (``Reason/interrupt(_:)``). Composition does not build a tree: combining two causes simply
/// concatenates their reasons, so a cause produced by concurrent work can contain several
/// failures, defects and interruptions at once. The empty cause is allowed and represents a
/// failure without any recorded reason.
///
/// ```swift
/// let cause = Cause<MyError>.fail(.notFound) + .die(RuntimeError("boom"))
/// cause.failures    // [.notFound]
/// cause.hasDies     // true
/// ```
public struct Cause<Failure: Error>: Error, Sendable {
    /// A single reason contained in a ``Cause``.
    public enum Reason: Sendable {
        /// An expected failure of the effect's typed error channel.
        case fail(Failure)
        /// An unexpected defect, e.g. a programming error or a violated invariant.
        case die(any Error)
        /// An interruption, optionally recording the fiber that requested it.
        case interrupt(FiberID?)
    }

    /// The reasons, in the order they were recorded.
    public let reasons: [Reason]

    /// Creates a cause from a list of reasons.
    public init(reasons: [Reason] = []) {
        self.reasons = reasons
    }

    /// The cause without any reason.
    public static var empty: Cause { Cause() }

    /// A cause holding a single typed failure.
    public static func fail(_ error: Failure) -> Cause {
        Cause(reasons: [.fail(error)])
    }

    /// A cause holding a single defect.
    public static func die(_ defect: any Error) -> Cause {
        Cause(reasons: [.die(defect)])
    }

    /// A cause holding a single interruption, optionally attributed to the interrupting fiber.
    public static func interrupt(_ fiberID: FiberID? = nil) -> Cause {
        Cause(reasons: [.interrupt(fiberID)])
    }

    /// Whether the cause contains no reasons.
    public var isEmpty: Bool { reasons.isEmpty }

    /// Concatenates the reasons of `self` and `other`.
    public func combine(_ other: Cause) -> Cause {
        if other.reasons.isEmpty { return self }
        if reasons.isEmpty { return other }
        return Cause(reasons: reasons + other.reasons)
    }

    /// Concatenates the reasons of two causes. Equivalent to ``combine(_:)``.
    public static func + (lhs: Cause, rhs: Cause) -> Cause {
        lhs.combine(rhs)
    }
}

extension Cause where Failure == Never {
    /// Converts a cause that cannot contain typed failures into a cause of any failure type.
    ///
    /// Defects and interruptions carry no typed payload, so this conversion is lossless.
    public func widen<E: Error>(to _: E.Type = E.self) -> Cause<E> {
        Cause<E>(reasons: reasons.map { reason in
            switch reason {
            case .die(let defect): .die(defect)
            case .interrupt(let id): .interrupt(id)
            }
        })
    }
}
