/// Explicit requirements for Music types that implement CustomReflectable.
public protocol PerformanceRequirementProviding: Music {
    @MainActor var performanceRequirements: [PerformanceRequirement] { get }
}
