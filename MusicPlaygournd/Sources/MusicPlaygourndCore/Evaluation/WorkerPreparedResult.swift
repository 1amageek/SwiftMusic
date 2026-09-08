import Foundation

/// The fixed-file payload published by a worker before a successful response.
public struct WorkerPreparedResult: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let generation: UInt64
    public let loop: PreparedLoop

    public init(revision: UInt64, generation: UInt64, loop: PreparedLoop) {
        self.revision = revision
        self.generation = generation
        self.loop = loop
    }
}
