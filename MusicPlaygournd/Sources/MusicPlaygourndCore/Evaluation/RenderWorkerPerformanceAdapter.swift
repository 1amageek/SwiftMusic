import Foundation
import SwiftMusic

/// MainActor-owned performance state retained by a generated evaluation worker.
///
/// The adapter is the only boundary that knows how to resolve a generated
/// `PerformanceEntry` model. Its key paths and model reference never cross the
/// worker protocol; only its validated metadata and values do.
@MainActor
public protocol RenderWorkerPerformanceAdapter: AnyObject, Sendable {
    var controls: [PerformanceControlMetadata] { get throws }
    func currentValues() throws -> [String: PerformanceControlValue]
    func validate(values: [String: PerformanceControlValue]) throws
    func apply(values: [String: PerformanceControlValue]) throws
    func prepare(
        revision: UInt64,
        source: String,
        fallbackBPM: Double,
        beatsPerBar: Int
    ) throws -> RenderWorkerPreparation
}
