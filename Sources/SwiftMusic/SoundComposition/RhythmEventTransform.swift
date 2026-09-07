/// A bounded transform applied to events in one periodic rhythm cycle.
public enum RhythmEventTransform: Sendable, Equatable, Hashable {
    case reversed
    case rotated(by: MusicalTime)
    case ratcheted(Int)
}
