public struct PlaybackSnapshot: Sendable, Equatable {
    public let loop: PreparedLoop?
    public let revision: UInt64?
    public let beatPosition: Double
    public let isPlaying: Bool

    public init(
        loop: PreparedLoop?,
        revision: UInt64?,
        beatPosition: Double,
        isPlaying: Bool
    ) {
        self.loop = loop
        self.revision = revision
        self.beatPosition = beatPosition
        self.isPlaying = isPlaying
    }
}
