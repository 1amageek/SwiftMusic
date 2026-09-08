public enum PreparedLoopValidationError: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    case invalidTelemetry(String)
    case invalidSampleRate(Double)
    case invalidBPM(Double)
    case invalidMeter(Int)
    case invalidBeatCount(Double)
    case invalidSampleCount(Int)
    case nonFiniteSample(index: Int)
    case tooManySamples(limit: Int)
    case tooManyEvents(limit: Int)
    case tooManyRows(limit: Int)
    case invalidRow(index: Int, reason: String)
    case invalidEvent(index: Int, reason: String)

    public var description: String {
        switch self {
        case .invalidTelemetry(let reason): "Invalid telemetry: \(reason)"
        case .invalidSampleRate(let value): "Invalid sample rate: \(value)"
        case .invalidBPM(let value): "Invalid BPM: \(value)"
        case .invalidMeter(let value): "Invalid beats per bar: \(value)"
        case .invalidBeatCount(let value): "Invalid beat count: \(value)"
        case .invalidSampleCount(let value): "Invalid sample count: \(value)"
        case .nonFiniteSample(let index): "Sample at index \(index) is not finite"
        case .tooManySamples(let limit): "Sample count exceeds limit \(limit)"
        case .tooManyEvents(let limit): "Event count exceeds limit \(limit)"
        case .tooManyRows(let limit): "Row count exceeds limit \(limit)"
        case .invalidRow(let index, let reason): "Invalid row \(index): \(reason)"
        case .invalidEvent(let index, let reason): "Invalid event \(index): \(reason)"
        }
    }
}
