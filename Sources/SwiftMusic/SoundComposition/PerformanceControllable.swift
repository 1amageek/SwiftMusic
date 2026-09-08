import Observation

/// An optional MainActor-owned control surface for an observable performance model.
@MainActor
public protocol PerformanceControllable: AnyObject, Observable, Sendable {
    var performanceModelID: String { get }
    var performanceControls: PerformanceControlSet<Self> { get throws }
}

@MainActor
public extension PerformanceControllable {
    func performanceControlMetadata() throws -> [PerformanceControlMetadata] {
        try performanceControls.metadata(modelID: performanceModelID, for: self)
    }

    func applyPerformanceControls(_ values: [String: PerformanceControlValue]) throws {
        let controls = try performanceControls
        try controls.validate(modelID: performanceModelID)
        try controls.apply(values: values, to: self)
    }

    func validatePerformanceControls(_ values: [String: PerformanceControlValue]) throws {
        let controls = try performanceControls
        try controls.validate(modelID: performanceModelID)
        try controls.validate(values: values)
    }
}
