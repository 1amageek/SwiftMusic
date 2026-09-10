/// Typed failures raised while constructing or resolving continuous automation.
public enum AutomationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPhase
    case invalidRate
    case invalidCycle
    case emptyValues
    case tooManyValues(limit: Int)
    case invalidValue(index: Int)
    case invalidPosition(index: Int)
    case invalidEndpoint
    case nonfiniteMappedValue
    case timingOverflow

    public var description: String {
        switch self {
        case .invalidPhase: "Automation phase must be finite and in 0..<1"
        case .invalidRate: "Automation rate must be finite and positive"
        case .invalidCycle: "Automation cycle must be finite and positive"
        case .emptyValues: "Automation values must not be empty"
        case .tooManyValues(let limit): "Automation values exceed limit \(limit)"
        case .invalidValue(let index): "Automation value at index \(index) is invalid"
        case .invalidPosition(let index): "Automation point at index \(index) has an invalid position"
        case .invalidEndpoint: "Automation endpoint is invalid"
        case .nonfiniteMappedValue: "Automation mapping produced a non-finite value"
        case .timingOverflow: "Automation timing arithmetic overflowed"
        }
    }
}
