/// The interpolation curve used by one ADSR envelope segment.
public enum EnvelopeCurve: Sendable, Equatable, Hashable {
    case linear
    case exponential(exponent: Double)
}
