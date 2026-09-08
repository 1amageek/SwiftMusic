import Foundation

public struct MIDIReceivedClockState: Codable, Sendable, Equatable {
    public let sourceID: MIDIEndpointID
    public let isRunning: Bool
    public let lastCommand: MIDIMessage?
    public let commandGeneration: UInt64
    public let pulseOrdinal: UInt64
    public let estimatedBPM: Double?

    public init(sourceID: MIDIEndpointID, isRunning: Bool,
                lastCommand: MIDIMessage?, commandGeneration: UInt64,
                pulseOrdinal: UInt64, estimatedBPM: Double?) {
        self.sourceID = sourceID
        self.isRunning = isRunning
        self.lastCommand = lastCommand
        self.commandGeneration = commandGeneration
        self.pulseOrdinal = pulseOrdinal
        self.estimatedBPM = estimatedBPM
    }

    public var beat: Double {
        Double(pulseOrdinal) / 24
    }
}
