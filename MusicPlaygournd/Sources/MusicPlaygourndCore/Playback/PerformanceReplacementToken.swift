import Foundation

/// Identifies one reserved performance replacement on its originating transport.
public struct PerformanceReplacementToken: Sendable, Equatable {
    internal let id: UUID
    internal init() { id = UUID() }
}
