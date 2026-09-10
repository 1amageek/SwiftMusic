/// An immutable, cyclic, one-cycle oscillator table.
public struct Wavetable: Sendable, Equatable, Hashable {
    public let samples: [Float]

    public init(samples: [Float]) throws {
        let count = samples.count
        guard (2...4_096).contains(count), count & (count - 1) == 0 else {
            throw SynthesizerDescriptorError.invalidWavetableLength
        }
        for (index, sample) in samples.enumerated() {
            guard sample.isFinite, (-1...1).contains(sample) else {
                throw SynthesizerDescriptorError.invalidWavetableSample(index: index)
            }
        }
        self.samples = samples
    }
}
