public protocol SampleLoading: Sendable {
    /// Loads only the requested region and rejects the budget before PCM allocation.
    func load(_ request: SampleLoadRequest) throws -> LoadedSample
}
