/// A pulse oscillator width expressed as the positive portion of one cycle.
public struct PulseWave: Sendable, Equatable, Hashable {
    public let width: Double

    public init(width: Double) throws {
        guard width.isFinite, width > 0, width < 1 else {
            throw SynthesizerDescriptorError.invalidPulseWidth
        }
        self.width = width
    }
}
