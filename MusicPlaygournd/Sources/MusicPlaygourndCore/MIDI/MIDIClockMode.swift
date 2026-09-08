import Foundation

public enum MIDIClockMode: Codable, Sendable, Equatable, Hashable {
    case off
    case send(output: MIDIEndpointID)
    case receive(input: MIDIEndpointID)
}

public enum MIDIClockHealth: Codable, Sendable, Equatable, Hashable {
    case unavailable
    case waitingForPulses
    case running
    case disconnected
    case failed(String)
}
