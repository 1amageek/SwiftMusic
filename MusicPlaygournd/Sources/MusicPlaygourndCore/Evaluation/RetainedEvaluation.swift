import SwiftMusic

/// The host-visible result of a worker that retains its compiled score.
public struct RetainedEvaluation: Sendable {
    public let loop: PreparedLoop
    public let catalog: LiveControlCatalog
    public let metadata: EditorSemanticMetadata
    public let performanceControls: [PerformanceControlMetadata]

    public init(
        loop: PreparedLoop,
        catalog: LiveControlCatalog,
        metadata: EditorSemanticMetadata? = nil,
        performanceControls: [PerformanceControlMetadata] = []
    ) {
        self.loop = loop
        self.catalog = catalog
        self.performanceControls = performanceControls
        if let metadata {
            self.metadata = metadata
        } else {
            // An empty metadata value is valid by construction and preserves source compatibility
            // for callers that create retained fixtures before semantic metadata is available.
            self.metadata = .empty
        }
    }
}
