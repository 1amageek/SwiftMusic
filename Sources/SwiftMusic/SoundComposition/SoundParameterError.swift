public enum SoundParameterError: Error, Equatable, Sendable {
    case invalidValue(String)
    case invalidRange(String)
    case invalidVoices
}
