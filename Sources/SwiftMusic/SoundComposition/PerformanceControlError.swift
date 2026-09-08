import Foundation

/// Typed admission failures for an observable performance-control set.
public enum PerformanceControlError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidModelID
    case invalidControlID
    case duplicateControlID(String)
    case multipleBeatsPerMinuteControls
    case invalidRange(String)
    case nonFiniteValue(String)
    case valueOutOfRange(String)
    case valueTypeMismatch(String)
    case missingValue(String)
    case unknownControl(String)
    case invalidMapping(String)

    public var description: String {
        switch self {
        case .invalidModelID:
            "Performance model ID must be non-empty UTF-8"
        case .invalidControlID:
            "Performance control ID must be non-empty UTF-8"
        case .duplicateControlID(let id):
            "Duplicate performance control ID: \(id)"
        case .multipleBeatsPerMinuteControls:
            "A performance control set may contain at most one beats-per-minute control"
        case .invalidRange(let id):
            "Invalid performance-control range: \(id)"
        case .nonFiniteValue(let id):
            "Non-finite performance-control value: \(id)"
        case .valueOutOfRange(let id):
            "Performance-control value is outside its range: \(id)"
        case .valueTypeMismatch(let id):
            "Performance-control value has the wrong type: \(id)"
        case .missingValue(let id):
            "Missing performance-control value: \(id)"
        case .unknownControl(let id):
            "Unknown performance-control ID: \(id)"
        case .invalidMapping(let reason):
            "Invalid performance-control mapping: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
