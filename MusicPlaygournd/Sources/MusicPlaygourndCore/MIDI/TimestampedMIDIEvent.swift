import Foundation

public struct TimestampedMIDIEvent: Codable, Sendable, Equatable {
    public let sourceID: MIDIEndpointID
    public let hostTime: UInt64
    public let message: MIDIMessage
    public let musicalBeat: Double?

    public init(sourceID: MIDIEndpointID, hostTime: UInt64,
                message: MIDIMessage, musicalBeat: Double? = nil) {
        self.sourceID = sourceID
        self.hostTime = hostTime
        self.message = message
        self.musicalBeat = musicalBeat
    }
}
