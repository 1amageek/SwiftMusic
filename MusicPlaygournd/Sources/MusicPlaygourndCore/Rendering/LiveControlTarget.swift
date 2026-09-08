import Foundation

public enum LiveControlTarget: Codable, Sendable, Equatable, Hashable {
    case source(Int)
    case renderNode(Int)
    case track(Int)
    case master
}
