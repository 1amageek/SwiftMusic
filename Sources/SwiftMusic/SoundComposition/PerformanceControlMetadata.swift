/// Wire-safe metadata for a mapped performance control.
public struct PerformanceControlMetadata: Codable, Sendable, Equatable, Hashable {
    public let modelID: String
    public let controlID: String
    public let label: String
    public let domain: PerformanceControlDomain
    public let value: PerformanceControlValue

    public init(
        modelID: String,
        controlID: String,
        label: String,
        domain: PerformanceControlDomain,
        value: PerformanceControlValue
    ) {
        self.modelID = modelID
        self.controlID = controlID
        self.label = label
        self.domain = domain
        self.value = value
    }

}
