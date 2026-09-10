public enum MusicalTimeError: Error, Equatable, Sendable {
    case invalidBeatsPerBar(Int)
    case zeroDenominator
    case divisionByZero
    case overflow
}
