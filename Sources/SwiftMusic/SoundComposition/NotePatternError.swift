public enum NotePatternError: Error, Equatable, Sendable {
    case emptyInput
    case emptyGroup(offset: Int)
    case invalidToken(token: String, index: Int)
    case pitchOutOfRange(token: String, index: Int)
    case unmatchedOpeningBracket(offset: Int)
    case unmatchedClosingBracket(offset: Int)
    case inputTooLong(limit: Int)
    case tooManyLeaves(limit: Int)
    case nestingTooDeep(limit: Int)
    case timingOverflow
}
