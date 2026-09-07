public enum ScoreCompilationError: Error, Equatable, Sendable {
    case zeroDuration
    case timeOverflow
    case maximumDepthExceeded(limit: Int)
    case maximumEventsExceeded(limit: Int)
    case maximumTracksExceeded(limit: Int)
}
