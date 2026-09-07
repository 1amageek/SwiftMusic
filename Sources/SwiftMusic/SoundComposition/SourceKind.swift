public enum SourceKind: Sendable, Equatable, Hashable {
    case sample(String)
    case synthesizer(Waveform)
}
