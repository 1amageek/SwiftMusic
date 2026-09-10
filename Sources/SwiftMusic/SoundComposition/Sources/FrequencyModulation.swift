/// A bounded sine-carrier frequency-modulation descriptor.
public struct FrequencyModulation: Sendable, Equatable, Hashable {
    public let ratio: Double
    public let index: Double

    public init(ratio: Double, index: Double) throws {
        guard ratio.isFinite, ratio > 0 else {
            throw SynthesizerDescriptorError.invalidFrequencyModulationRatio
        }
        guard index.isFinite, index >= 0 else {
            throw SynthesizerDescriptorError.invalidFrequencyModulationIndex
        }
        self.ratio = ratio
        self.index = index
    }
}
