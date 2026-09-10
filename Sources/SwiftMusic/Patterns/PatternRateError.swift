/// Errors raised while resolving a deferred pattern rate.
public enum PatternRateError: Error, Equatable, Sendable {
    case nonPositiveValue
    case nonFiniteValue
    case zeroDenominator
    case overflow
}
