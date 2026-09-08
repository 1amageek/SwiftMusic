import Foundation
import SwiftMusic

/// Typed failures that leave the retained worker and adopted PCM available.
public enum RenderWorkerVisualizationFailure: Codable, Sendable, Equatable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case unknownAddress(LiveControlAddress)
    case unsupported(LiveControlAddress)
    case invalidValue(LiveControlAddress)
    case invalidData
    case pointLimit
    case cancelled
    case failed(String)
}

/// Responses emitted by a retained evaluation worker.
public enum RenderWorkerResponse: Codable, Sendable, Equatable {
    case ready(revision: UInt64, catalog: LiveControlCatalog,
               performanceControls: [PerformanceControlMetadata])
    case rendered(revision: UInt64, generation: UInt64, operationID: UInt64)
    case performanceRendered(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        catalog: LiveControlCatalog,
        performanceControls: [PerformanceControlMetadata]
    )
    case performanceFailed(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        diagnostic: WorkerCompilerDiagnostic
    )
    case performanceAdopted(revision: UInt64, generation: UInt64, operationID: UInt64, accepted: Bool)
    case performanceDiscarded(revision: UInt64, generation: UInt64, operationID: UInt64)
    case stemsExported(snapshot: StemExportSnapshot, operationID: UInt64)
    case visualized(revision: UInt64, selectionGeneration: UInt64, operationID: UInt64,
                    visualization: PreparedControlVisualization)
    case visualizationFailed(revision: UInt64, selectionGeneration: UInt64, operationID: UInt64,
                             failure: RenderWorkerVisualizationFailure)
    case failed(revision: UInt64, generation: UInt64, operationID: UInt64, message: String)
    case shutdownComplete
}

public extension RenderWorkerResponse {
    static func ready(revision: UInt64, catalog: LiveControlCatalog) -> Self {
        .ready(revision: revision, catalog: catalog, performanceControls: [])
    }

    static func rendered(revision: UInt64, generation: UInt64) -> Self {
        .rendered(revision: revision, generation: generation, operationID: generation)
    }

    static func stemsExported(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        manifest: [StemExportManifest]
    ) -> Self {
        .stemsExported(
            snapshot: StemExportSnapshot(revision: revision, generation: generation, manifest: manifest),
            operationID: operationID
        )
    }

    static func stemsExported(
        revision: UInt64,
        generation: UInt64,
        manifest: [StemExportManifest]
    ) -> Self {
        .stemsExported(
            snapshot: StemExportSnapshot(revision: revision, generation: generation, manifest: manifest),
            operationID: generation
        )
    }

    static func failed(revision: UInt64, generation: UInt64, message: String) -> Self {
        .failed(revision: revision, generation: generation, operationID: generation, message: message)
    }
}
