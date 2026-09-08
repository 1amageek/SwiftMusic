import Foundation

public enum MIDIMessage: Codable, Sendable, Equatable, Hashable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int, velocity: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case clock
    case start
    case `continue`
    case stop

    public var normalized: MIDIMessage {
        if case .noteOn(let channel, let note, 0) = self {
            return .noteOff(channel: channel, note: note, velocity: 0)
        }
        return self
    }

    public func validated() throws -> MIDIMessage {
        let value = normalized
        switch value {
        case .noteOn(let channel, let note, let velocity),
             .noteOff(let channel, let note, let velocity):
            try Self.validateChannel(channel)
            try Self.validateSevenBit(note, name: "note")
            try Self.validateSevenBit(velocity, name: "velocity")
        case .controlChange(let channel, let controller, let value):
            try Self.validateChannel(channel)
            try Self.validateSevenBit(controller, name: "controller")
            try Self.validateSevenBit(value, name: "value")
        case .clock, .start, .continue, .stop:
            break
        }
        return value
    }

    private static func validateChannel(_ channel: Int) throws {
        guard (1...16).contains(channel) else {
            throw MIDIError.invalidMessage("channel must be in 1...16")
        }
    }

    private static func validateSevenBit(_ value: Int, name: String) throws {
        guard (0...127).contains(value) else {
            throw MIDIError.invalidMessage("\(name) must be in 0...127")
        }
    }
}
