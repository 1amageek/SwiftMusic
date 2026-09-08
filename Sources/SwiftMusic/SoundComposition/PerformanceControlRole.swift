/// The clock role of a numeric performance control.
public enum PerformanceControlRole: String, Codable, Sendable, Equatable, Hashable {
    case scalar
    case beatsPerMinute
}
