import Foundation

/// Responses emitted by a retained evaluation worker.
public enum RenderWorkerResponse: Codable, Sendable, Equatable {
    case ready(revision: UInt64, catalog: LiveControlCatalog)
    case rendered(revision: UInt64, generation: UInt64)
    case failed(revision: UInt64, generation: UInt64, message: String)
    case shutdownComplete
}
