import Foundation

public struct LiveControlDescriptor: Codable, Sendable, Hashable {
    public let address: LiveControlAddress
    public let label: String
    public let presentation: LiveControlPresentation?
    public let baseline: LiveControlBaseline

    public init(address: LiveControlAddress, label: String, baseline: LiveControlBaseline, presentation: LiveControlPresentation? = nil) {
        self.address = address
        self.label = label
        self.baseline = baseline
        self.presentation = presentation
    }
}
