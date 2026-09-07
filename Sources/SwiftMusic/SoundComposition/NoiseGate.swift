/// A noise gate descriptor with bounded attack and release times.
public struct NoiseGate: Sendable, Equatable, Hashable {
    public let thresholdDecibels: Double
    public let attackSeconds: Double
    public let releaseSeconds: Double

    public init(
        threshold: Decibels,
        attack: Duration,
        release: Duration
    ) throws {
        self.thresholdDecibels = threshold.value
        self.attackSeconds = try _dynamicsDurationSeconds(attack)
        self.releaseSeconds = try _dynamicsDurationSeconds(release)
    }
}
