/// A source descriptor required by a client audio backend.
public struct CompiledSource: Sendable, Equatable {
    public internal(set) var id: Int
    public internal(set) var kind: SourceKind
    public internal(set) var tuning: Tuning?
    public internal(set) var envelope: Envelope?
    public internal(set) var pitchEnvelope: EnvelopeModulation?
    public internal(set) var filterEnvelope: EnvelopeModulation?
    public internal(set) var sampleRegion: SampleRegion?
    public internal(set) var filter: SourceFilter?
    public internal(set) var unison: Unison?
    public internal(set) var patternAnchor: SoundSourceAnchor?
    public internal(set) var patternText: String?

    internal init(
        id: Int,
        kind: SourceKind,
        tuning: Tuning? = nil,
        envelope: Envelope? = nil,
        pitchEnvelope: EnvelopeModulation? = nil,
        filterEnvelope: EnvelopeModulation? = nil,
        sampleRegion: SampleRegion? = nil,
        unison: Unison? = nil,
        filter: SourceFilter? = nil,
        patternAnchor: SoundSourceAnchor? = nil,
        patternText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.tuning = tuning
        self.envelope = envelope
        self.pitchEnvelope = pitchEnvelope
        self.filterEnvelope = filterEnvelope
        self.sampleRegion = sampleRegion
        self.unison = unison
        self.filter = filter
        self.patternAnchor = patternAnchor
        self.patternText = patternText
    }
}
