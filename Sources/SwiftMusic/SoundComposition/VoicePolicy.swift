/// The optional per-source voice allocation policy consumed by a native renderer.
public enum VoicePolicy: Sendable, Equatable, Hashable {
    case monophonic
    case polyphonic(limit: Int, stealing: VoiceStealing)
}
