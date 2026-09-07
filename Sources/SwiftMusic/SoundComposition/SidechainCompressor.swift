/// A compressor descriptor with an optional named-bus detector.
public struct SidechainCompressor: Sendable, Equatable, Hashable {
    public let thresholdDecibels: Double
    public let ratio: Double
    public let attackSeconds: Double
    public let releaseSeconds: Double
    public let kneeDecibels: Double
    public let sidechainBus: String?

    public init(
        threshold: Decibels,
        ratio: Double,
        attack: Duration,
        release: Duration,
        knee: Decibels,
        sidechainBus: String? = nil
    ) throws {
        guard ratio.isFinite, ratio >= 1 else {
            throw SoundParameterError.invalidRange("compressor ratio")
        }
        guard knee.value >= 0 else {
            throw SoundParameterError.invalidRange("compressor knee")
        }
        if let sidechainBus, !_dynamicsBusNameIsValid(sidechainBus) {
            throw SoundParameterError.invalidValue("sidechain bus")
        }
        self.thresholdDecibels = threshold.value
        self.ratio = ratio
        self.attackSeconds = try _dynamicsDurationSeconds(attack)
        self.releaseSeconds = try _dynamicsDurationSeconds(release)
        self.kneeDecibels = knee.value
        self.sidechainBus = sidechainBus
    }
}
