import Foundation

public enum LoopRenderingError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidBPM(Double)
    case invalidMeter(Int)
    case extentTooLong(Double)
    case durationTooLong(Double)
    case tooManySources(limit: Int)
    case tooManyEvents(limit: Int)
    case tooManyRenderNodes(limit: Int)
    case unsupportedSource(sourceID: Int, kind: String)
    case unsupportedSourceSetting(sourceID: Int, setting: String)
    case unsupportedEventSetting(index: Int, setting: String)
    case unsupportedRenderNode(index: Int, operation: String)
    case sampleCacheLimitExceeded(limit: Int)
    case invalidSound(String)
    case invalidEvent(index: Int, reason: String)
    case nonPeriodicModulationState
    case nonPeriodicDynamicsState
    case nonPeriodicVoiceAllocation
    case overflow
    case invalidPreparedLoop(PreparedLoopValidationError)

    public var description: String {
        switch self {
        case .invalidBPM(let value): "BPM must be between 40 and 240: \(value)"
        case .invalidMeter(let value): "Beats per bar must be between 2 and 7: \(value)"
        case .extentTooLong(let value): "Sound extent exceeds 32 beats: \(value)"
        case .durationTooLong(let value): "Rendered loop exceeds 16 seconds: \(value)"
        case .tooManySources(let limit): "Source count exceeds limit \(limit)"
        case .tooManyEvents(let limit): "Event count exceeds limit \(limit)"
        case .tooManyRenderNodes(let limit): "Render-node count exceeds limit \(limit)"
        case .unsupportedSource(let sourceID, let kind): "Unsupported source \(sourceID): \(kind)"
        case .unsupportedSourceSetting(let sourceID, let setting): "Unsupported source setting on \(sourceID): \(setting)"
        case .unsupportedEventSetting(let index, let setting): "Unsupported event setting on \(index): \(setting)"
        case .unsupportedRenderNode(let index, let operation): "Unsupported render node \(index): \(operation)"
        case .sampleCacheLimitExceeded(let limit): "Decoded sample cache exceeds limit \(limit)"
        case .invalidSound(let reason): "Invalid compiled sound: \(reason)"
        case .invalidEvent(let index, let reason): "Invalid event \(index): \(reason)"
        case .nonPeriodicModulationState: "Modulation state does not repeat at the loop boundary"
        case .nonPeriodicDynamicsState: "Dynamics state does not repeat at the loop boundary"
        case .nonPeriodicVoiceAllocation: "Voice allocation does not repeat at the loop boundary"
        case .overflow: "Audio rendering arithmetic overflow"
        case .invalidPreparedLoop(let error): "Invalid prepared loop: \(error)"
        }
    }
}
