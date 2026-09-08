import Foundation

/// The retained worker setup produced by one source compilation.
public struct RenderWorkerPreparation: Sendable {
    public let session: LoopRenderSession
    public let metadata: EditorSemanticMetadata?

    public init(session: LoopRenderSession, metadata: EditorSemanticMetadata? = nil) {
        self.session = session
        self.metadata = metadata
    }
}

/// The fixed-file payload published by a worker before a successful response.
public struct WorkerPreparedResult: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let generation: UInt64
    public let loop: PreparedLoop
    public let metadata: EditorSemanticMetadata?

    public init(
        revision: UInt64,
        generation: UInt64,
        loop: PreparedLoop,
        metadata: EditorSemanticMetadata? = nil
    ) {
        self.revision = revision
        self.generation = generation
        self.loop = loop
        self.metadata = metadata
    }
}
