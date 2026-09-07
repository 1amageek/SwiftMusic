/// An immutable beat-domain event emitted by `SoundCompiler`.
public struct CompiledSoundEvent: Sendable, Equatable {
    public internal(set) var sourceID: Int
    public internal(set) var trackID: Int?
    public internal(set) var start: MusicalTime
    public internal(set) var duration: MusicalTime
    public internal(set) var pitch: Pitch?
    public internal(set) var velocity: Int
    public internal(set) var gate: Double
    public internal(set) var gain: Double
    public internal(set) var pan: Double?
    public internal(set) var sampleKey: String?
    public internal(set) var pitchOffsetSemitones: Double
    public internal(set) var cutoffHz: Double?
    public internal(set) var envelope: Envelope?
    public internal(set) var patternStepIndex: Int?
    public internal(set) var harmonyGroupID: Int? = nil
    public internal(set) var harmonyOccurrenceID: Int? = nil
    public internal(set) var harmonyVoiceIndex: Int? = nil
    public internal(set) var portamentoStartMIDINote: Double? = nil
    internal var legato: Legato? = nil
    internal var pendingEventDucks: [_PendingEventDuck]

    internal init(
        sourceID: Int,
        trackID: Int?,
        start: MusicalTime,
        duration: MusicalTime,
        pitch: Pitch?,
        velocity: Int = 80,
        gate: Double = 1,
        gain: Double = 1,
        pan: Double? = nil,
        sampleKey: String? = nil,
        pitchOffsetSemitones: Double = 0,
        cutoffHz: Double? = nil,
        envelope: Envelope? = nil,
        patternStepIndex: Int? = nil,
        pendingEventDucks: [_PendingEventDuck] = []
    ) {
        self.sourceID = sourceID
        self.trackID = trackID
        self.start = start
        self.duration = duration
        self.pitch = pitch
        self.velocity = velocity
        self.gate = gate
        self.gain = gain
        self.pan = pan
        self.sampleKey = sampleKey
        self.pitchOffsetSemitones = pitchOffsetSemitones
        self.cutoffHz = cutoffHz
        self.envelope = envelope
        self.patternStepIndex = patternStepIndex
        self.pendingEventDucks = pendingEventDucks
    }
}
