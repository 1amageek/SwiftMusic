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
    public internal(set) var patternStepIndex: Int?

    internal init(
        sourceID: Int,
        trackID: Int?,
        start: MusicalTime,
        duration: MusicalTime,
        pitch: Pitch?,
        velocity: Int = 80,
        gate: Double = 1,
        gain: Double = 1,
        patternStepIndex: Int? = nil
    ) {
        self.sourceID = sourceID
        self.trackID = trackID
        self.start = start
        self.duration = duration
        self.pitch = pitch
        self.velocity = velocity
        self.gate = gate
        self.gain = gain
        self.patternStepIndex = patternStepIndex
    }
}
