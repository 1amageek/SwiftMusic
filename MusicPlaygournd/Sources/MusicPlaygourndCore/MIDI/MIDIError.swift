import Foundation

public enum MIDIError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidEndpointID(Int32)
    case duplicateEndpoint(MIDIEndpointID)
    case endpointNotFound(MIDIEndpointID)
    case invalidEndpointName
    case invalidMessage(String)
    case unsupportedMessage(String)
    case invalidTimestamp(UInt64)
    case timestampsNotNondecreasing
    case timestampTooFar
    case tooManyMessages(limit: Int)
    case tooManyActiveNotes(limit: Int)
    case disconnectedEndpoint(MIDIEndpointID)
    case coreMIDIStatus(Int32)
    case streamAlreadyClaimed
    case serviceShutDown
    case clockUnavailable
    case clockDiscontinuity
    case invalidClock(String)
    case unsupportedProjection(MIDIProjectionLimitation)
    case invalidLoop(String)

    public var description: String {
        switch self {
        case .invalidEndpointID(let value): "Invalid MIDI endpoint ID: \(value)"
        case .duplicateEndpoint(let id): "Duplicate MIDI endpoint ID: \(id.rawValue)"
        case .endpointNotFound(let id): "MIDI endpoint not found: \(id.rawValue)"
        case .invalidEndpointName: "MIDI endpoint name is empty"
        case .invalidMessage(let reason): "Invalid MIDI message: \(reason)"
        case .unsupportedMessage(let reason): "Unsupported MIDI message: \(reason)"
        case .invalidTimestamp(let value): "Invalid MIDI timestamp: \(value)"
        case .timestampsNotNondecreasing: "MIDI timestamps are not nondecreasing"
        case .timestampTooFar: "MIDI timestamp is more than one second ahead"
        case .tooManyActiveNotes(let limit): "MIDI active note count exceeds \(limit)"
        case .tooManyMessages(let limit): "MIDI message count exceeds \(limit)"
        case .disconnectedEndpoint(let id): "MIDI endpoint is disconnected: \(id.rawValue)"
        case .coreMIDIStatus(let status): "CoreMIDI returned OSStatus \(status)"
        case .streamAlreadyClaimed: "MIDI event stream is already claimed"
        case .serviceShutDown: "MIDI service has shut down"
        case .clockUnavailable: "MIDI clock anchor is unavailable"
        case .clockDiscontinuity: "MIDI clock timestamp is discontinuous"
        case .invalidClock(let reason): "Invalid MIDI clock state: \(reason)"
        case .unsupportedProjection(let limitation): "MIDI projection is unsupported: \(limitation.rawValue)"
        case .invalidLoop(let reason): "Invalid MIDI loop schedule: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
