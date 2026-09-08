import Foundation

/// Responses emitted by a retained evaluation worker.
public enum RenderWorkerResponse: Codable, Sendable, Equatable {
    case ready(revision: UInt64, catalog: LiveControlCatalog)
    case rendered(revision: UInt64, generation: UInt64, operationID: UInt64)
    case stemsExported(snapshot: StemExportSnapshot, operationID: UInt64)
    case failed(revision: UInt64, generation: UInt64, operationID: UInt64, message: String)
    case shutdownComplete
}

public extension RenderWorkerResponse {
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
