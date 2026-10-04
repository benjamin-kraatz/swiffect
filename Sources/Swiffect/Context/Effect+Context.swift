extension Effect {
    /// Accesses a service from the fiber's context.
    ///
    /// References (``ReferenceKey``) fall back to their default value. Any other missing
    /// service is a defect (``MissingServiceError``).
    ///
    /// ```swift
    /// let users = Effect.service(UserRepositoryKey.self).flatMap { $0.find(42) }
    /// ```
    public static func service<K: ServiceKey>(_ key: K.Type) -> Effect where Success == K.Value {
        Effect(unsafe: { fiber in
            if let value = fiber.context.getOptional(key) { return .success(value) }
            return .die(MissingServiceError(key: K.name))
        })
    }

    /// Accesses a service from the fiber's context, or `nil` if it is missing. References
    /// fall back to their default value.
    public static func serviceOption<K: ServiceKey>(_ key: K.Type) -> Effect where Success == K.Value? {
        Effect(unsafe: { fiber in .success(fiber.context.getOptional(key)) })
    }

    /// Runs the effect with `value` provided for `key`. The service is visible to the effect
    /// and to fibers it forks; the surrounding context is unaffected.
    ///
    /// ```swift
    /// let result = program.provideService(UserRepositoryKey.self, InMemoryUsers())
    /// ```
    public func provideService<K: ServiceKey>(_ key: K.Type, _ value: K.Value) -> Effect {
        updateContext { $0.adding(key, value) }
    }

    /// Runs the effect with every service of `context` added to (and overriding) the current
    /// context.
    public func provideContext(_ context: Context) -> Effect {
        updateContext { $0.merging(context) }
    }

    /// Runs the effect with the service for `key` replaced by `update(current)`. The current
    /// value must exist (or be a reference with a default); otherwise this is a defect.
    public func updateService<K: ServiceKey>(_ key: K.Type, _ update: @escaping @Sendable (K.Value) -> K.Value) -> Effect {
        Effect(unsafe: { fiber in
            guard let current = fiber.context.getOptional(key) else {
                return .die(MissingServiceError(key: K.name))
            }
            return await self.unsafeRun(in: fiber.withContext(fiber.context.adding(key, update(current))))
        })
    }

    /// Runs the effect with the context transformed by `update`.
    public func updateContext(_ update: @escaping @Sendable (Context) -> Context) -> Effect {
        Effect(unsafe: { fiber in await self.unsafeRun(in: fiber.updatingContext(update)) })
    }
}

extension Effect where Success == Context {
    /// The fiber's current context.
    public static var context: Effect {
        Effect(unsafe: { fiber in .success(fiber.context) })
    }
}

extension Effect where Failure == Never {
    /// Accesses a service from the fiber's context (infallible default overload).
    public static func service<K: ServiceKey>(_ key: K.Type) -> Effect where Success == K.Value {
        Effect(unsafe: { fiber in
            if let value = fiber.context.getOptional(key) { return .success(value) }
            return .die(MissingServiceError(key: K.name))
        })
    }

    /// Accesses an optional service from the fiber's context (infallible default overload).
    public static func serviceOption<K: ServiceKey>(_ key: K.Type) -> Effect where Success == K.Value? {
        Effect(unsafe: { fiber in .success(fiber.context.getOptional(key)) })
    }
}

extension Effect where Success == Context, Failure == Never {
    /// The fiber's current context.
    public static var context: Effect {
        Effect(unsafe: { fiber in .success(fiber.context) })
    }
}
