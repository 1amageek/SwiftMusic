import Foundation

public struct LiveControlAddress: Codable, Sendable, Equatable, Hashable {
    public let revision: UInt64
    public let target: LiveControlTarget
    public let parameter: LiveControlParameter

    public init(revision: UInt64, target: LiveControlTarget, parameter: LiveControlParameter) {
        self.revision = revision
        self.target = target
        self.parameter = parameter
    }
}
