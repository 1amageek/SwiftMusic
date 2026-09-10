/// Selects the point at which a Track send observes the track signal.
public enum TrackSendPlacement: Sendable, Equatable, Hashable {
    case preFader
    case postFader
}
