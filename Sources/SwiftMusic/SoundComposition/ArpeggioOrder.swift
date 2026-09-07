/// The order used to emit voices from one simultaneous harmony group.
public enum ArpeggioOrder: Sendable, Equatable, Hashable {
    case asDeclared
    case up
    case down
    case upDown
}
