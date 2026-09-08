import Observation

/// A music declaration and its explicitly owned, process-local models.
public struct PerformanceMusic<Base: Music>: Sendable {
    internal let base: Base
    internal var models: [ObjectIdentifier: any Sendable]

    @MainActor public func performance<Model: AnyObject & Observable & Sendable>(_ model: Model) -> Self {
        var result = self
        result.models[ObjectIdentifier(Model.self)] = model
        return result
    }
}

public extension Music {
    @MainActor func performance<Model: AnyObject & Observable & Sendable>(_ model: Model) -> PerformanceMusic<Self> {
        PerformanceMusic(base: self, models: [ObjectIdentifier(Model.self): model])
    }
}
