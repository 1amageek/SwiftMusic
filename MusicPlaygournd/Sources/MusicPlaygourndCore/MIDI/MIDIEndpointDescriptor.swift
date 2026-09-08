import Foundation

public enum MIDIEndpointDirection: String, Codable, Sendable, Equatable {
    case input
    case output
}

public struct MIDIEndpointDescriptor: Codable, Sendable, Equatable, Hashable {
    public let id: MIDIEndpointID
    public let displayName: String
    public let direction: MIDIEndpointDirection
    public let isVirtual: Bool

    public init(id: MIDIEndpointID, displayName: String,
                direction: MIDIEndpointDirection, isVirtual: Bool) throws {
        guard !displayName.isEmpty else { throw MIDIError.invalidEndpointName }
        self.id = id
        self.displayName = displayName
        self.direction = direction
        self.isVirtual = isVirtual
    }
}
