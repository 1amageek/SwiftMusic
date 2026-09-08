import Foundation
import SwiftMusic

/// Commands accepted by a retained evaluation worker.
public enum RenderWorkerCommand: Codable, Sendable, Equatable {
    case render(revision: UInt64, generation: UInt64, operationID: UInt64, overrides: [LiveControlOverride])
    case renderPerformance(
        revision: UInt64,
        generation: UInt64,
        operationID: UInt64,
        modelID: String,
        values: [String: PerformanceControlValue],
        overrides: [LiveControlOverride]
    )
    case adoptPerformance(revision: UInt64, generation: UInt64, operationID: UInt64)
    case discardPerformance(revision: UInt64, generation: UInt64, operationID: UInt64)
    case exportStems(revision: UInt64, generation: UInt64, operationID: UInt64, overrides: [LiveControlOverride], destination: URL)
    case visualize(revision: UInt64, selectionGeneration: UInt64, operationID: UInt64,
                   address: LiveControlAddress, overrides: [LiveControlOverride])
    case cancelExport(operationID: UInt64)
    case cancelVisualization(operationID: UInt64)
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
