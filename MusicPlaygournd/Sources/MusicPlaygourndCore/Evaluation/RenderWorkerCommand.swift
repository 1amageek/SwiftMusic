import Foundation

/// Commands accepted by a retained evaluation worker.
public enum RenderWorkerCommand: Codable, Sendable, Equatable {
    case render(revision: UInt64, generation: UInt64, operationID: UInt64, overrides: [LiveControlOverride])
    case exportStems(revision: UInt64, generation: UInt64, operationID: UInt64, overrides: [LiveControlOverride], destination: URL)
    case cancelExport(operationID: UInt64)
    case shutdown
}

public extension RenderWorkerCommand {
    static func render(revision: UInt64, generation: UInt64, overrides: [LiveControlOverride]) -> Self {
        .render(revision: revision, generation: generation, operationID: generation, overrides: overrides)
    }

    static func exportStems(
        revision: UInt64,
        generation: UInt64,
        overrides: [LiveControlOverride],
        destination: URL
    ) -> Self {
        .exportStems(
            revision: revision,
            generation: generation,
            operationID: generation,
            overrides: overrides,
            destination: destination
        )
    }
}
