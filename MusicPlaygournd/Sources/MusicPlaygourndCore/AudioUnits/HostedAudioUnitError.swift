import Foundation

public enum HostedAudioUnitError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedComponentType(UInt32)
    case invalidDescriptor
    case tooManyComponents
    case duplicateComponent
    case missingComponent
    case invalidState
    case stateUnavailable
    case stateIdentityMismatch
    case notLoaded
    case instantiationFailed(String)
    case timedOut
    case superseded
    case incompatibleFormat(String)
    case invalidLatency
    case graphFailed(String)
    case rollbackFailed(String, String)

    public var description: String {
        switch self {
        case let .unsupportedComponentType(type):
            return "Unsupported Audio Unit component type: \(type)."
        case .invalidDescriptor:
            return "The Audio Unit descriptor is invalid."
        case .tooManyComponents:
            return "The Audio Unit component limit was exceeded."
        case .duplicateComponent:
            return "The Audio Unit component list contains a duplicate identity."
        case .missingComponent:
            return "The requested Audio Unit component is unavailable."
        case .invalidState:
            return "The Audio Unit document state is invalid."
        case .stateUnavailable:
            return "The Audio Unit document state is unavailable."
        case .stateIdentityMismatch:
            return "The document state belongs to another Audio Unit."
        case .notLoaded:
            return "No Audio Unit is loaded."
        case let .instantiationFailed(message):
            return "Audio Unit instantiation failed: \(message)"
        case .timedOut:
            return "Audio Unit instantiation timed out."
        case .superseded:
            return "The Audio Unit request was superseded."
        case let .incompatibleFormat(message):
            return "The Audio Unit format is incompatible: \(message)"
        case .invalidLatency:
            return "The Audio Unit reported invalid latency."
        case let .graphFailed(message):
            return "The Audio Unit graph operation failed: \(message)"
        case let .rollbackFailed(graph, rollback):
            return "The Audio Unit graph failed (\(graph)); rollback failed (\(rollback))."
        }
    }

    public var errorDescription: String? { description }
}
