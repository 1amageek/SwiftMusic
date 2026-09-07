/// A source descriptor required by a client audio backend.
public struct CompiledSource: Sendable, Equatable {
    public internal(set) var id: Int
    public internal(set) var kind: SourceKind
    public internal(set) var tuning: Tuning?
    public internal(set) var envelope: Envelope?
    public internal(set) var sampleRegion: SampleRegion?
    public internal(set) var unison: Unison?

    internal init(
        id: Int,
        kind: SourceKind,
        tuning: Tuning? = nil,
        envelope: Envelope? = nil,
        sampleRegion: SampleRegion? = nil,
        unison: Unison? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tuning = tuning
        self.envelope = envelope
        self.sampleRegion = sampleRegion
        self.unison = unison
    }
}
