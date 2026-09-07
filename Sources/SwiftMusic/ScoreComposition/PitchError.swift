public enum PitchError: Error, Equatable, Sendable {
    case outOfRange(UInt8)
}
