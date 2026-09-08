import Foundation

public enum LiveControlBaseline: Codable, Sendable, Hashable {
    case scalar(Double)
    case bypassed
    case automation
}
