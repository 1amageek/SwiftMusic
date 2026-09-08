import Foundation

public struct LiveControlOverride: Codable, Sendable, Equatable, Hashable {
    public let address: LiveControlAddress
    public let value: LiveControlValue

    public init(address: LiveControlAddress, value: LiveControlValue) {
        self.address = address
        self.value = value
    }
}
