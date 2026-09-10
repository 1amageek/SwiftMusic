/// A hard-ceiling dynamics descriptor with a bounded release time.
public struct Limiter: Sendable, Equatable, Hashable {
    public let ceilingDecibels: Double
    public let releaseSeconds: Double

    public init(ceiling: Decibels, release: Duration) throws {
        guard ceiling.value <= 0 else {
            throw SoundParameterError.invalidRange("limiter ceiling")
        }
        self.ceilingDecibels = ceiling.value
        self.releaseSeconds = try _dynamicsDurationSeconds(release)
    }
}
