import Foundation

public enum LiveControlError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidCatalog(String)
    case unknownAddress(LiveControlAddress)
    case unsupportedAddress(LiveControlAddress)
    case duplicateAddress(LiveControlAddress)
    case invalidValue(LiveControlAddress)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .staleRevision(let expected, let actual): "Control revision \(actual) does not match adopted revision \(expected)"
        case .invalidCatalog(let reason): "Invalid control catalog: \(reason)"
        case .unknownAddress(let address): "Unknown control address: \(address)"
        case .unsupportedAddress(let address): "Unsupported control address: \(address)"
        case .duplicateAddress(let address): "Duplicate control address: \(address)"
        case .invalidValue(let address): "Invalid control value for \(address)"
        }
    }
}
