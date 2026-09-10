/// An exact subdivision delay applied to alternating rhythm cells.
public struct Swing: Sendable, Equatable, Hashable {
    public let subdivision: MusicalTime
    public let delay: MusicalTime

    /// Creates a swing descriptor whose delay fits within one subdivision.
    public init(subdivision: MusicalTime = .eighth, delay: MusicalTime) throws {
        guard subdivision.numerator != 0, delay < subdivision else {
            throw RhythmTransformError.invalidSwing
        }
        self.subdivision = subdivision
        self.delay = delay
    }
}
