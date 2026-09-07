public struct SampleRegion: Sendable, Equatable, Hashable {
    public let startFraction: Double
    public let endFraction: Double

    public init(startFraction: Double, endFraction: Double) throws {
        guard startFraction.isFinite, endFraction.isFinite,
              (0...1).contains(startFraction), (0...1).contains(endFraction),
              startFraction < endFraction else {
            throw SoundParameterError.invalidRange("sample region")
        }
        self.startFraction = startFraction
        self.endFraction = endFraction
    }
}
