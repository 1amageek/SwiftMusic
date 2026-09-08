/// A serializable admission domain for one performance control.
public enum PerformanceControlDomain: Codable, Sendable, Equatable, Hashable {
    case double(range: ClosedRange<Double>, role: PerformanceControlRole)
    case position(xRange: ClosedRange<Double>, depthRange: ClosedRange<Double>)
}
