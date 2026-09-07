/// The complete immutable result of compiling one score declaration.
public struct CompiledScore: Sendable, Equatable {
    public let events: [CompiledNoteEvent]
    public let tracks: [CompiledTrack]
    public let extent: MusicalTime

    internal init(
        events: [CompiledNoteEvent],
        tracks: [CompiledTrack],
        extent: MusicalTime
    ) {
        self.events = events
        self.tracks = tracks
        self.extent = extent
    }
}
