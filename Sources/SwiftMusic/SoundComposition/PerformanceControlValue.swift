/// The bounded value domains exposed by a performance model.
public enum PerformanceControlValue: Codable, Sendable, Equatable, Hashable {
    case double(Double)
    case position(SpatialPosition)
}
