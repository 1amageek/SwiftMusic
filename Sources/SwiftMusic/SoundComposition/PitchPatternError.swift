/// Located failures while resolving a pitch-offset pattern.
public enum PitchPatternError: Error, Equatable, Sendable {
    case emptyInput
    case emptyTypedValues
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int, offset: Int = 0)
    case nonFiniteValue(token: String, index: Int, offset: Int = 0)
    case invalidRepetition(token: String, index: Int, offset: Int = 0)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case unmatchedOpeningAngleBracket(offset: Int)
    case unmatchedClosingAngleBracket(offset: Int)
    case inputTooLong(limit: Int, offset: Int = 0)
    case tooManyLeaves(limit: Int, offset: Int = 0)
    case tooManyTypedValues(limit: Int)
    case nestingTooDeep(limit: Int, offset: Int = 0)
    case timingOverflow(offset: Int? = nil)
    case zeroFactor
    case invalidRate(PatternRateError)

    /// The zero-based UTF-8 source position, or nil for typed and transform failures.
    public var utf8Offset: Int? {
        switch self {
        case .emptyInput: 0
        case .emptyTypedValues, .tooManyTypedValues, .zeroFactor, .invalidRate: nil
        case .emptyGroup(let offset),
             .unmatchedOpeningBracket(let offset),
             .unmatchedClosingBracket(let offset),
             .unmatchedOpeningAngleBracket(let offset),
             .unmatchedClosingAngleBracket(let offset): offset
        case .timingOverflow(let offset): offset
        case .invalidToken(_, _, let offset),
             .nonFiniteValue(_, _, let offset),
             .invalidRepetition(_, _, let offset): offset
        case .inputTooLong(_, let offset),
             .tooManyLeaves(_, let offset),
             .nestingTooDeep(_, let offset): offset
        }
    }
}
