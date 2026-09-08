import SwiftMusic

/// The host-visible result of a worker that retains its compiled score.
public struct RetainedEvaluation: Sendable {
    public let loop: PreparedLoop
    public let catalog: LiveControlCatalog
    public let metadata: EditorSemanticMetadata
    public let performanceControls: [PerformanceControlMetadata]
    public let performanceTransferIssue: PerformanceControlError?

    public init(
        loop: PreparedLoop,
        catalog: LiveControlCatalog,
        metadata: EditorSemanticMetadata? = nil,
        performanceControls: [PerformanceControlMetadata] = [],
        performanceTransferIssue: PerformanceControlError? = nil
    ) {
        self.loop = loop
        self.catalog = catalog
        self.performanceControls = performanceControls
        self.performanceTransferIssue = performanceTransferIssue
        if let metadata {
            self.metadata = metadata
        } else {
            // An empty metadata value is valid by construction and preserves source compatibility
            // for callers that create retained fixtures before semantic metadata is available.
            self.metadata = .empty
        }
    }
}
