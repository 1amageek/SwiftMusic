/// The bounded host window used when compiling recurring sound programs.
public struct LiveLoopPolicy: Sendable, Equatable {
    public let beatsPerBar: Int
    public let maximumBeats: MusicalTime

    public init(beatsPerBar: Int, maximumBeats: MusicalTime) throws {
        guard beatsPerBar > 0 else {
            throw SoundCompilationError.invalidParameter("Beats per bar must be positive")
        }
        guard maximumBeats > .zero else {
            throw SoundCompilationError.invalidParameter("Maximum live beats must be positive")
        }
        self.beatsPerBar = beatsPerBar
        self.maximumBeats = maximumBeats
    }
}
