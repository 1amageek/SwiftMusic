/// Typed failures produced while resolving named internal buses.
public enum BusRoutingError: Error, Equatable, Sendable {
    case invalidName(String)
    case duplicateReturn(String)
    case emptyReturn(String)
    case missingReturn(String)
    case cycle
    case maximumBusesExceeded(limit: Int)
    case maximumEdgesExceeded(limit: Int)
}
