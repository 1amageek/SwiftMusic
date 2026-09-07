public struct LoopEvent: Codable, Sendable, Equatable {
    public let sourceID: Int
    public let label: String
    public let startBeat: Double
    public let durationBeats: Double
    public let midiNote: Int?
    public let velocity: Int
    public let patternStepIndex: Int?

    public init(
        sourceID: Int,
        label: String,
        startBeat: Double,
        durationBeats: Double,
        midiNote: Int?,
        velocity: Int,
        patternStepIndex: Int? = nil
    ) {
        self.sourceID = sourceID
        self.label = label
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.midiNote = midiNote
        self.velocity = velocity
        self.patternStepIndex = patternStepIndex
    }
}
