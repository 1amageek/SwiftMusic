import Foundation

public struct MIDIEndpointID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) throws {
        guard rawValue != 0 else { throw MIDIError.invalidEndpointID(rawValue) }
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int32) throws {
        try self.init(rawValue: rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { String(rawValue) }
}
