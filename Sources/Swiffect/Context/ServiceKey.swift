/// A type that identifies a service stored in a ``Context``.
///
/// Keys are types, much like SwiftUI's `EnvironmentKey`: the key type is used for lookup and
/// its associated ``Value`` is the type of the stored service. A key can be a dedicated
/// caseless enum, or the service type itself:
///
/// ```swift
/// protocol UserRepository: Sendable {
///     func find(_ id: Int) -> Effect<User, RepoError>
/// }
///
/// enum UserRepositoryKey: ServiceKey {
///     typealias Value = any UserRepository
/// }
///
/// // A concrete service can also be its own key:
/// struct Greeter: ServiceKey {
///     typealias Value = Greeter
///     var greeting: String
/// }
///
/// let program = Effect.service(Greeter.self).map { "\($0.greeting), world" }
/// let result = try await program.provideService(Greeter.self, Greeter(greeting: "Hello")).run()
/// ```
///
/// Looking up a key that has not been provided and has no default value is a defect
/// (``MissingServiceError``). Keys with a default value conform to ``ReferenceKey``.
public protocol ServiceKey: Sendable {
    /// The type of the service stored under this key.
    associatedtype Value: Sendable

    /// A human readable name, used in error messages. Defaults to the key's type name.
    static var name: String { get }
}

extension ServiceKey {
    /// The fully qualified name of the key type.
    public static var name: String { String(reflecting: Self.self) }
}

/// A service key with a default value, used when the key has not been provided.
///
/// References replace Effect's `FiberRef`: fiber-local, scoped state is expressed by
/// providing a different value for a region of an effect with
/// ``Effect/provideService(_:_:)``. Forked fibers inherit a snapshot of their parent's context
/// and therefore its references.
///
/// ```swift
/// enum RequestID: ReferenceKey {
///     static var defaultValue: String { "none" }
/// }
///
/// let id = Effect.service(RequestID.self)                // "none"
/// let scoped = id.provideService(RequestID.self, "r-42") // "r-42"
/// ```
///
/// Later layers of the library (loggers, log levels, annotations, the clock) are all
/// expressed as references.
public protocol ReferenceKey: ServiceKey {
    // Restated so the type of `defaultValue` infers `Value` in conforming types.
    associatedtype Value

    /// The value used when the key has not been provided.
    static var defaultValue: Value { get }
}
