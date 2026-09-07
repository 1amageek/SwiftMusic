public enum Waveform: Sendable, Equatable, Hashable {
    case sine
    case square
    case saw
    case triangle
    case noise

    public static let sawtooth = Waveform.saw
}
