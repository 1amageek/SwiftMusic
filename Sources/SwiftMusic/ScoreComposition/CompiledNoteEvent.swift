/// An immutable pitched event in exact musical time.
public struct CompiledNoteEvent: Sendable, Equatable {
    public let pitch: Pitch
    public let start: MusicalTime
    public let duration: MusicalTime
    public let trackID: Int?

    internal let traversalIndex: Int

    internal init(
        pitch: Pitch,
        start: MusicalTime,
        duration: MusicalTime,
        trackID: Int?,
        traversalIndex: Int
    ) {
        self.pitch = pitch
        self.start = start
        self.duration = duration
        self.trackID = trackID
        self.traversalIndex = traversalIndex
    }

    public static func == (lhs: CompiledNoteEvent, rhs: CompiledNoteEvent) -> Bool {
        lhs.pitch == rhs.pitch &&
            lhs.start == rhs.start &&
            lhs.duration == rhs.duration &&
            lhs.trackID == rhs.trackID
    }
}
