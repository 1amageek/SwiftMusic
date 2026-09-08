import Observation

/// An exact model type required by a custom-reflected Music declaration.
public struct PerformanceRequirement: Sendable {
    internal let identifier: ObjectIdentifier
    internal let name: String

    public init<Model: AnyObject & Observable & Sendable>(_ type: Model.Type) {
        identifier = ObjectIdentifier(type)
        name = String(reflecting: type)
    }
}

internal protocol _PerformanceRequirement {
    var requirement: PerformanceRequirement { get }
}
