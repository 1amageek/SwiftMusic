/// The spectral color of a deterministic noise oscillator.
public enum NoiseColor: Sendable, Equatable, Hashable {
    case white
    case pink
    case brown
}

/// A deterministic noise oscillator descriptor.
public struct Noise: Sendable, Equatable, Hashable {
    public let color: NoiseColor
    public let seed: UInt64

    public init(color: NoiseColor, seed: UInt64 = 0) {
        self.color = color
        self.seed = seed
    }
}
