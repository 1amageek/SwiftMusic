/// A synthesizer source descriptor. PCM generation belongs to a client backend.
public struct Synthesizer: Sound, Sendable, Equatable {
    public typealias Body = Never

    public let waveform: Waveform

    public init(_ waveform: Waveform) {
        self.waveform = waveform
    }

    public var body: Never {
        fatalError("Synthesizer is a compiler terminal")
    }
}

extension Synthesizer: _SoundPrimitive {
    internal var _node: _SoundNode {
        .synthesizer(waveform)
    }
}
