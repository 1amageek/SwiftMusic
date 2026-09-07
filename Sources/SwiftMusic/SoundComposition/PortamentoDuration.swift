/// A portamento duration expressed in physical seconds or musical beats.
public enum PortamentoDuration: Sendable, Equatable, Hashable {
    case seconds(Duration)
    case beats(MusicalTime)
}
