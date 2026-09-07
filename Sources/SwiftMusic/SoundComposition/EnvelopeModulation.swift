/// A source-level envelope and its signed modulation depth.
public struct EnvelopeModulation: Sendable, Equatable, Hashable {
    public let envelope: Envelope
    public let depth: Semitones

    public init(envelope: Envelope, depth: Semitones) {
        self.envelope = envelope
        self.depth = depth
    }
}
