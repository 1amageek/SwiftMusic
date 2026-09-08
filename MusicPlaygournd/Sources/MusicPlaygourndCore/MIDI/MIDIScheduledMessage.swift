import Foundation

public struct MIDIScheduledMessage: Codable, Sendable, Equatable {
    public let hostTime: UInt64
    public let message: MIDIMessage

    public init(hostTime: UInt64, message: MIDIMessage) {
        self.hostTime = hostTime
        self.message = message
    }
}
