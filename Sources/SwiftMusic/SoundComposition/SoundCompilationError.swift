public enum SoundCompilationError: Error, Equatable, Sendable {
    case invalidParameter(String)
    case unsupportedSourceSetting(String)
    case missingPitch
    case pitchOutOfRange
    case timeOverflow
    case maximumDepthExceeded(limit: Int)
    case maximumEventsExceeded(limit: Int)
    case maximumTracksExceeded(limit: Int)
    case maximumSourcesExceeded(limit: Int)
    case maximumRenderNodesExceeded(limit: Int)
}
