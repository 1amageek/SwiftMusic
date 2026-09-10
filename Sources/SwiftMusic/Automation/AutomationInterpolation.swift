/// Interpolation used by the segment after an automation curve point.
public enum AutomationInterpolation: Sendable, Equatable, Hashable {
    case hold
    case linear
    case smoothstep
}
