/// Describes whether a compiled event window is finite or intended to loop seamlessly.
public enum CompiledPlaybackMode: Sendable, Equatable {
    case finite
    case seamlessLoop
}
