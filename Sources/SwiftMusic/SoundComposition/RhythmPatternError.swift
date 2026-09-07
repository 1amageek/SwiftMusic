public enum RhythmPatternError: Error, Equatable, Sendable {
    case emptyInput
    case invalidToken(token: String, index: Int)
}
