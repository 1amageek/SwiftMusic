import Foundation

public enum LiveControlValue: Codable, Sendable, Equatable, Hashable {
    case number(Double)
    case bypassed
}
