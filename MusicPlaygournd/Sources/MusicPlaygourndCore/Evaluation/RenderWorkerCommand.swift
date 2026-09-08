import Foundation

/// Commands accepted by a retained evaluation worker.
public enum RenderWorkerCommand: Codable, Sendable, Equatable {
    case render(revision: UInt64, generation: UInt64, overrides: [LiveControlOverride])
    case shutdown
}
