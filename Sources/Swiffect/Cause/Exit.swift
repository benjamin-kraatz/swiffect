/// The outcome of running an effect: either a value or the ``Cause`` of its failure.
///
/// ```swift
/// let exit = await Effect<Int, MyError>.fail(.notFound).runExit()
/// switch exit {
/// case .success(let value): print(value)
/// case .failure(let cause): print(cause.pretty)
/// }
/// ```
public enum Exit<Success: Sendable, Failure: Error>: Sendable {
    /// The effect completed with a value.
    case success(Success)
    /// The effect failed, died or was interrupted.
    case failure(Cause<Failure>)

    /// A successful exit.
    public static func succeed(_ value: Success) -> Exit { .success(value) }

    /// An exit failing with a single typed failure.
    public static func fail(_ error: Failure) -> Exit { .failure(.fail(error)) }

    /// An exit failing with a single defect.
    public static func die(_ defect: any Error) -> Exit { .failure(.die(defect)) }

    /// An exit failing with a single interruption.
    public static func interrupt(_ fiberID: FiberID? = nil) -> Exit { .failure(.interrupt(fiberID)) }

    /// Whether the exit is a success.
    public var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    /// Whether the exit is a failure.
    public var isFailure: Bool { !isSuccess }

    /// Whether the exit is a failure whose cause contains an interruption.
    public var isInterrupted: Bool {
        if case .failure(let cause) = self { cause.hasInterrupts } else { false }
    }

    /// The success value, if any.
    public var value: Success? {
        if case .success(let value) = self { value } else { nil }
    }

    /// The failure cause, if any.
    public var cause: Cause<Failure>? {
        if case .failure(let cause) = self { cause } else { nil }
    }

    /// Transforms the success value.
    public func map<B: Sendable>(_ transform: (Success) -> B) -> Exit<B, Failure> {
        switch self {
        case .success(let value): .success(transform(value))
        case .failure(let cause): .failure(cause)
        }
    }

    /// Transforms the typed failures of the cause.
    public func mapError<E2: Error>(_ transform: (Failure) -> E2) -> Exit<Success, E2> {
        switch self {
        case .success(let value): .success(value)
        case .failure(let cause): .failure(cause.map(transform))
        }
    }

    /// Returns the value or throws.
    ///
    /// A plain failure (a cause made only of typed failures) throws its first `Failure` value.
    /// Any other cause (defects, interruptions, the empty cause) throws a ``FiberFailure``.
    public func get() throws -> Success {
        switch self {
        case .success(let value):
            return value
        case .failure(let cause):
            if cause.hasFailsOnly, let failure = cause.firstFailure { throw failure }
            throw FiberFailure(cause)
        }
    }

    /// The exit with its value and error types erased, as passed to scope finalizers.
    public var erased: AnyExit {
        switch self {
        case .success(let value): .success(value)
        case .failure(let cause): .failure(cause.erased)
        }
    }
}

extension Exit where Success == Void {
    /// The successful exit carrying no value.
    public static var void: Exit { .success(()) }
}

extension Exit where Failure == Never {
    /// Converts an infallible exit into an exit of any failure type.
    public func widen<E: Error>(to _: E.Type = E.self) -> Exit<Success, E> {
        switch self {
        case .success(let value): .success(value)
        case .failure(let cause): .failure(cause.widen())
        }
    }
}

/// A type-erased exit, used where the concrete value and error types are irrelevant, such as
/// scope finalizers.
public typealias AnyExit = Exit<any Sendable, any Error>
