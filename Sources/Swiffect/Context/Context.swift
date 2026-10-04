/// An immutable, type-keyed collection of services.
///
/// Every fiber carries a context. Effects read services from it with
/// ``Effect/service(_:)`` and replace parts of it for a region with
/// ``Effect/provideService(_:_:)`` or ``Effect/provideContext(_:)``. Because the TypeScript
/// `R` type parameter is not modelled, requirements are checked at runtime: a missing service
/// without a default is a defect.
///
/// `Context` is a value type and is safe to share between fibers.
///
/// ```swift
/// let context = Context()
///     .adding(DatabaseKey.self, LiveDatabase())
///     .adding(RequestID.self, "r-1")
/// ```
public struct Context: Sendable {
    private var storage: [ObjectIdentifier: any Sendable]

    /// Creates an empty context.
    public init() {
        storage = [:]
    }

    /// The empty context.
    public static var empty: Context { Context() }

    /// The number of services explicitly stored in the context.
    public var count: Int { storage.count }

    /// Whether a value has been explicitly stored for `key`. Default values of references do
    /// not count.
    public func contains<K: ServiceKey>(_ key: K.Type) -> Bool {
        storage[ObjectIdentifier(key)] != nil
    }

    /// Returns the value stored for `key`, falling back to the default value when `key` is a
    /// ``ReferenceKey``. Returns `nil` when the service is absent and has no default.
    public func getOptional<K: ServiceKey>(_ key: K.Type) -> K.Value? {
        if let value = storage[ObjectIdentifier(key)] {
            return (value as! K.Value)
        }
        if let reference = key as? any ReferenceKey.Type {
            return Self.defaultValue(of: reference) as? K.Value
        }
        return nil
    }

    /// Returns the value of a reference, or its default value when it has not been provided.
    public func get<K: ReferenceKey>(_ key: K.Type) -> K.Value {
        if let value = storage[ObjectIdentifier(key)] {
            return value as! K.Value
        }
        return K.defaultValue
    }

    /// Returns a copy of the context with `value` stored for `key`, replacing any previous
    /// value.
    public func adding<K: ServiceKey>(_ key: K.Type, _ value: K.Value) -> Context {
        var copy = self
        copy.add(key, value)
        return copy
    }

    /// Stores `value` for `key`, replacing any previous value.
    public mutating func add<K: ServiceKey>(_ key: K.Type, _ value: K.Value) {
        storage[ObjectIdentifier(key)] = value
    }

    /// Returns a copy of the context without a value for `key`.
    public func removing<K: ServiceKey>(_ key: K.Type) -> Context {
        var copy = self
        copy.remove(key)
        return copy
    }

    /// Removes the value stored for `key`.
    public mutating func remove<K: ServiceKey>(_ key: K.Type) {
        storage[ObjectIdentifier(key)] = nil
    }

    /// Returns a context containing the services of both contexts. Services in `other` win.
    public func merging(_ other: Context) -> Context {
        var copy = self
        copy.merge(other)
        return copy
    }

    /// Adds every service of `other`, replacing existing values for the same keys.
    public mutating func merge(_ other: Context) {
        if storage.isEmpty {
            storage = other.storage
        } else {
            storage.merge(other.storage) { _, new in new }
        }
    }

    private static func defaultValue<R: ReferenceKey>(of _: R.Type) -> any Sendable {
        R.defaultValue
    }
}
