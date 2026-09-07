public struct LoopEvent: Codable, Sendable, Equatable {
    public let sourceID: Int
    public let label: String
    public let startBeat: Double
    public let durationBeats: Double
    public let midiNote: Int?
    public let pan: Double?
    public let gain: Double
    public let velocity: Int
    public let patternStepIndex: Int?

    public init(
        sourceID: Int,
        label: String,
        startBeat: Double,
        durationBeats: Double,
        midiNote: Int?,
        velocity: Int,
        patternStepIndex: Int? = nil,
        gain: Double = 1,
        pan: Double? = nil
    ) {
        self.sourceID = sourceID
        self.label = label
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.midiNote = midiNote
        self.pan = pan
        self.gain = gain
        self.velocity = velocity
        self.patternStepIndex = patternStepIndex
    }
}
