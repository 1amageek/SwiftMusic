public struct PlaybackSnapshot: Sendable, Equatable {
    public let loop: PreparedLoop?
    public let revision: UInt64?
    public let beatPosition: Double
    public let isPlaying: Bool
    public let overrideGeneration: UInt64

    public init(
        loop: PreparedLoop?,
        revision: UInt64?,
        beatPosition: Double,
        isPlaying: Bool,
        overrideGeneration: UInt64 = 0
    ) {
        self.loop = loop
        self.revision = revision
        self.beatPosition = beatPosition
        self.isPlaying = isPlaying
        self.overrideGeneration = overrideGeneration
    }
}
