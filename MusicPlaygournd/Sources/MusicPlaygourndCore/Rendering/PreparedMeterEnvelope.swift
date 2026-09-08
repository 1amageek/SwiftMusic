import Foundation

/// Peaks at a rendered Track or named BusReturn boundary, before master processing.
public struct PreparedMeterEnvelope: Codable, Sendable, Equatable {
    public enum Target: Codable, Sendable, Hashable { case track(Int), bus(String) }
    public let target: Target
    public let label: String
    public let peaks: [Float]
    public var clipFlags: [Bool] { peaks.map { $0 >= 1 } }

    public init(target: Target, label: String, peaks: [Float]) {
        self.target = target
        self.label = label
        self.peaks = peaks
    }

    internal func validate() throws {
        guard !label.isEmpty, !peaks.isEmpty, peaks.count <= PreparedLoop.maximumPeakBins,
              peaks.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw PreparedLoopValidationError.invalidTelemetry("Invalid meter envelope")
        }
        switch target {
        case .track(let id):
            guard (0..<32).contains(id) else { throw PreparedLoopValidationError.invalidTelemetry("Invalid Track identity") }
        case .bus(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PreparedLoopValidationError.invalidTelemetry("Empty Bus identity") }
        }
    }
}
