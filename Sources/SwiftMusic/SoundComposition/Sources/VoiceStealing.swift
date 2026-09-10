/// The deterministic rule used when a source voice limit is reached.
public enum VoiceStealing: Sendable, Equatable, Hashable {
    case oldest
    case quietest
}
