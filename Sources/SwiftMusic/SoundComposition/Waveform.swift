public enum Waveform: Sendable, Equatable, Hashable {
    case sine
    case square
    case saw
    case triangle
    case noise
    case bandLimitedSaw
    case pulse(PulseWave)
    case frequencyModulation(FrequencyModulation)
    case coloredNoise(Noise)
    case wavetable(Wavetable)

    public static let sawtooth = Waveform.saw

    internal var supportsPitchTraversal: Bool {
        switch self {
        case .noise, .coloredNoise:
            false
        case .sine, .square, .saw, .triangle, .bandLimitedSaw, .pulse,
             .frequencyModulation, .wavetable:
            true
        }
    }
}
