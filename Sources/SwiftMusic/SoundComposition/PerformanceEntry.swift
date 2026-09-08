import Observation

/// An explicit model factory used by hosts that construct an editor session.
public protocol PerformanceEntry: Music {
    associatedtype PerformanceModel: AnyObject & Observable & Sendable
    @MainActor static func makePerformanceModel() -> PerformanceModel
}
