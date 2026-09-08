/// Typed failures raised while constructing immutable synthesizer descriptors.
public enum SynthesizerDescriptorError: Error, Equatable, Sendable {
    case invalidPulseWidth
    case invalidFrequencyModulationRatio
    case invalidFrequencyModulationIndex
    case invalidWavetableLength
    case invalidWavetableSample(index: Int)
}
