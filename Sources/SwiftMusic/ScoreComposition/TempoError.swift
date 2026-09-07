public enum TempoError: Error, Equatable, Sendable {
    case nonFiniteBeatsPerMinute
    case nonPositiveBeatsPerMinute
    case zeroBeatUnit
    case nonFiniteSeconds
}
