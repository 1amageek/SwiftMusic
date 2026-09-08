/// The host-visible result of a worker that retains its compiled score.
public struct RetainedEvaluation: Sendable {
    public let loop: PreparedLoop
    public let catalog: LiveControlCatalog

    public init(loop: PreparedLoop, catalog: LiveControlCatalog) {
        self.loop = loop
        self.catalog = catalog
    }
}
