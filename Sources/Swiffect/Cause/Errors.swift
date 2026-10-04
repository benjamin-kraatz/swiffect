/// The failure produced by ``Effect/timeout(_:)`` when the time limit elapses first.
public struct TimeoutError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The time limit that was exceeded.
    public let duration: Duration

    /// Creates a timeout error for the given time limit.
    public init(duration: Duration) {
        self.duration = duration
    }

    /// A human readable description of the error.
    public var description: String { "TimeoutError: operation timed out after \(duration)" }
}

/// The failure produced when an expected element is missing, e.g. by
/// ``Effect/fromOptional(_:)`` on `nil`.
public struct NoSuchElementError: Error, Hashable, Sendable, CustomStringConvertible {
    /// An optional explanation.
    public let message: String?

    /// Creates the error with an optional message.
    public init(_ message: String? = nil) {
        self.message = message
    }

    /// A human readable description of the error.
    public var description: String {
        message.map { "NoSuchElementError: \($0)" } ?? "NoSuchElementError"
    }
}

/// A defect described only by a message, produced by ``Effect/die(message:)``.
public struct RuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The message describing the defect.
    public let message: String

    /// Creates the defect with a message.
    public init(_ message: String) {
        self.message = message
    }

    /// A human readable description of the error.
    public var description: String { "RuntimeError: \(message)" }
}

/// The defect raised when an effect requires a service that is missing from the fiber's
/// ``Context`` and has no default value.
public struct MissingServiceError: Error, Hashable, Sendable, CustomStringConvertible {
    /// The fully qualified name of the missing service key.
    public let key: String

    /// Creates the error for the given key name.
    public init(key: String) {
        self.key = key
    }

    /// A human readable description of the error.
    public var description: String { "MissingServiceError: service not found: \(key)" }
}

/// The error thrown to plain Swift callers when an effect's cause cannot be represented by a
/// single typed failure: defects, interruptions, several reasons, or the empty cause.
///
/// Thrown by ``Effect/run(context:)``, ``Exit/get()`` and the ``Effect/gen(_:)`` binder.
///
/// ```swift
/// do {
///     _ = try await program.run()
/// } catch let failure as FiberFailure where failure.isInterruption {
///     // the effect was interrupted
/// }
/// ```
public struct FiberFailure: Error, Sendable, CustomStringConvertible {
    /// The complete cause, with typed failures erased to `any Error`.
    public let cause: Cause<any Error>

    /// The original, statically typed cause (a `Cause<E>` boxed as `any Sendable`). Used to
    /// restore the exact cause when the failure crosses back into an effect.
    let typedCause: any Sendable

    /// Wraps a cause.
    public init<E: Error>(_ cause: Cause<E>) {
        self.cause = cause.erased
        self.typedCause = cause
    }

    /// Whether the cause consists of interruptions only.
    public var isInterruption: Bool { cause.hasInterruptsOnly }

    /// A human readable description of the error.
    public var description: String { "FiberFailure:\n\(cause.pretty)" }

    /// Recovers the statically typed cause, if it was created with failure type `E`.
    func typed<E: Error>(as _: E.Type) -> Cause<E>? {
        typedCause as? Cause<E>
    }
}
