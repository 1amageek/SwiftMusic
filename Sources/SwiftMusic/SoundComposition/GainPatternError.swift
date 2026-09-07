/// Errors raised while validating a per-event gain pattern.
public enum GainPatternError: Error, Equatable, Sendable {
    case emptyInput
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int)
    case negativeValue(token: String, index: Int)
    case nonFiniteValue(token: String, index: Int)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case inputTooLong(limit: Int)
    case tooManyLeaves(limit: Int)
    case nestingTooDeep(limit: Int)
    case timingOverflow
}
