/// The event boundary at which an envelope release begins.
public enum EnvelopeReleaseAnchor: Sendable, Equatable, Hashable {
    case gateEnd
    case eventEnd
}
