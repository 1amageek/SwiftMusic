import Foundation

public struct MIDIServiceSnapshot: Codable, Sendable, Equatable {
    public let connectedInputIDs: [MIDIEndpointID]
    public let outputID: MIDIEndpointID?
    public let clockMode: MIDIClockMode
    public let clockHealth: MIDIClockHealth
    public let receivedClock: MIDIReceivedClockState?
    public let droppedEventCount: UInt64

    public init(connectedInputIDs: [MIDIEndpointID], outputID: MIDIEndpointID?,
                clockMode: MIDIClockMode, clockHealth: MIDIClockHealth,
                receivedClock: MIDIReceivedClockState?, droppedEventCount: UInt64) {
        self.connectedInputIDs = connectedInputIDs
        self.outputID = outputID
        self.clockMode = clockMode
        self.clockHealth = clockHealth
        self.receivedClock = receivedClock
        self.droppedEventCount = droppedEventCount
    }
}
