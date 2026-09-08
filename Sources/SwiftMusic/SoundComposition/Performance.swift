import Observation

/// Reads an explicitly injected model while Music is evaluated by the compiler.
/// Access outside a validated evaluation scope is a programmer precondition failure.
@propertyWrapper
public struct Performance<Model: AnyObject & Observable & Sendable>: Sendable {
    public init(_ type: Model.Type) {}

    @MainActor public var wrappedValue: Model {
        guard let model = _PerformanceScope.models[ObjectIdentifier(Model.self)] as? Model else {
            preconditionFailure("Performance must be resolved through SoundCompiler before reading Music.body")
        }
        return model
    }
}

extension Performance: _PerformanceRequirement {
    var requirement: PerformanceRequirement { PerformanceRequirement(Model.self) }
}
