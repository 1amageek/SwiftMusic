public enum MusicalTimeError: Error, Equatable, Sendable {
    case zeroDenominator
    case overflow
}
