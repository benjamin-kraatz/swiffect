extension Cause: CustomStringConvertible {
    /// A human readable, multi-line rendering of every reason.
    ///
    /// Each reason is rendered on its own line:
    ///
    /// ```text
    /// Fail: notFound(id: 3)
    /// Die: RuntimeError: connection lost
    /// Interrupt: interrupted by fiber #7
    /// ```
    ///
    /// The empty cause renders as `Empty`.
    public var pretty: String {
        if reasons.isEmpty { return "Empty" }
        return reasons.map(\.pretty).joined(separator: "\n")
    }

    /// The same as ``pretty``.
    public var description: String { pretty }
}

extension Cause.Reason: CustomStringConvertible {
    /// A single-line rendering of the reason.
    public var pretty: String {
        switch self {
        case .fail(let error):
            "Fail: \(renderError(error))"
        case .die(let defect):
            "Die: \(renderError(defect))"
        case .interrupt(let id?):
            "Interrupt: interrupted by fiber \(id)"
        case .interrupt(nil):
            "Interrupt: interrupted"
        }
    }

    /// The same as ``pretty``.
    public var description: String { pretty }
}

/// Renders an error as `TypeName: description` unless the description already starts with the
/// type name (as is the case for most enums and structs printed by the standard library).
func renderError(_ error: any Error) -> String {
    let typeName = String(describing: type(of: error))
    let text = String(describing: error)
    if text.hasPrefix(typeName) { return text }
    return "\(typeName): \(text)"
}
