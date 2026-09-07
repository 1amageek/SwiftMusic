/// Errors raised while resolving a per-event pan pattern.
public enum PanPatternError: Error, Equatable, Sendable {
    case emptyInput
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int)
    case nonFiniteValue(token: String, index: Int)
    case outOfRangeValue(token: String, index: Int)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case inputTooLong(limit: Int)
    case tooManyLeaves(limit: Int)
    case nestingTooDeep(limit: Int)
    case timingOverflow
    case zeroFactor
    case invalidRate(PatternRateError)
}
