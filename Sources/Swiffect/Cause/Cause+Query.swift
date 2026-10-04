extension Cause {
    /// Whether at least one reason is a typed failure.
    public var hasFails: Bool {
        reasons.contains { if case .fail = $0 { true } else { false } }
    }

    /// Whether at least one reason is a defect.
    public var hasDies: Bool {
        reasons.contains { if case .die = $0 { true } else { false } }
    }

    /// Whether at least one reason is an interruption.
    public var hasInterrupts: Bool {
        reasons.contains { if case .interrupt = $0 { true } else { false } }
    }

    /// Whether the cause is non-empty and consists of interruptions only.
    public var hasInterruptsOnly: Bool {
        !reasons.isEmpty && reasons.allSatisfy { if case .interrupt = $0 { true } else { false } }
    }

    /// Whether the cause is non-empty and consists of typed failures only.
    ///
    /// Such a cause is a "plain" failure: it can be faithfully represented by throwing its
    /// first failure (see ``Exit/get()``).
    public var hasFailsOnly: Bool {
        !reasons.isEmpty && reasons.allSatisfy { if case .fail = $0 { true } else { false } }
    }

    /// All typed failures, in order.
    public var failures: [Failure] {
        reasons.compactMap { if case .fail(let error) = $0 { error } else { nil } }
    }

    /// All defects, in order.
    public var defects: [any Error] {
        reasons.compactMap { if case .die(let defect) = $0 { defect } else { nil } }
    }

    /// The identifiers of all fibers recorded as interruptors.
    public var interruptors: Set<FiberID> {
        Set(reasons.compactMap { if case .interrupt(let id) = $0 { id } else { nil } })
    }

    /// The first typed failure, if any (Effect's `findErrorOption`).
    public var firstFailure: Failure? {
        for reason in reasons { if case .fail(let error) = reason { return error } }
        return nil
    }

    /// The first defect, if any (Effect's `findDefect`).
    public var firstDefect: (any Error)? {
        for reason in reasons { if case .die(let defect) = reason { return defect } }
        return nil
    }

    /// Transforms every typed failure, keeping defects and interruptions.
    public func map<E2: Error>(_ transform: (Failure) -> E2) -> Cause<E2> {
        Cause<E2>(reasons: reasons.map { reason in
            switch reason {
            case .fail(let error): .fail(transform(error))
            case .die(let defect): .die(defect)
            case .interrupt(let id): .interrupt(id)
            }
        })
    }

    /// Removes all typed failures, keeping defects and interruptions.
    public func stripFailures() -> Cause<Never> {
        Cause<Never>(reasons: reasons.compactMap { reason in
            switch reason {
            case .fail: nil
            case .die(let defect): .die(defect)
            case .interrupt(let id): .interrupt(id)
            }
        })
    }

    /// Converts every typed failure into a defect.
    public func failuresAsDefects() -> Cause<Never> {
        Cause<Never>(reasons: reasons.map { reason in
            switch reason {
            case .fail(let error): .die(error)
            case .die(let defect): .die(defect)
            case .interrupt(let id): .interrupt(id)
            }
        })
    }

    /// Reduces the cause to a single Swift error.
    ///
    /// Returns the first typed failure, otherwise the first defect, otherwise a
    /// ``FiberFailure`` wrapping the whole cause (for interruptions and the empty cause).
    public var squash: any Error {
        if let failure = firstFailure { return failure }
        if let defect = firstDefect { return defect }
        return FiberFailure(self)
    }

    /// Converts the cause into a cause of `any Error`, preserving every reason.
    public var erased: Cause<any Error> {
        map { $0 as any Error }
    }
}
