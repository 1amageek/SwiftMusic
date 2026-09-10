/// Normalized oscillator shapes used by an `LFO`.
public enum LFOWaveform: Sendable, Equatable, Hashable {
    case sine
    case triangle
    case sawUp
    case sawDown
    case square
}
