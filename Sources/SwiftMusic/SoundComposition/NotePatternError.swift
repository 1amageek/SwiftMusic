public enum NotePatternError: Error, Equatable, Sendable {
    case emptyInput
    case invalidToken(token: String, index: Int)
    case pitchOutOfRange(token: String, index: Int)
}
