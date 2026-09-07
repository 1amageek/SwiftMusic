/// The complete immutable output of compiling one sound declaration.
public struct CompiledSound: Sendable, Equatable {
    public internal(set) var events: [CompiledSoundEvent]
    public internal(set) var tracks: [CompiledTrack]
    public internal(set) var sources: [CompiledSource]
    public internal(set) var renderNodes: [CompiledRenderNode]
    public internal(set) var rootNodeIDs: [Int]
    public internal(set) var extent: MusicalTime
    public internal(set) var playbackMode: CompiledPlaybackMode

    internal init(
        events: [CompiledSoundEvent],
        tracks: [CompiledTrack],
        sources: [CompiledSource],
        renderNodes: [CompiledRenderNode],
        rootNodeIDs: [Int],
        extent: MusicalTime,
        playbackMode: CompiledPlaybackMode = .finite
    ) {
        self.events = events
        self.tracks = tracks
        self.sources = sources
        self.renderNodes = renderNodes
        self.rootNodeIDs = rootNodeIDs
        self.extent = extent
        self.playbackMode = playbackMode
    }
}
