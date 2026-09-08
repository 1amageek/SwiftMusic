internal enum _PerformanceScope {
    @TaskLocal static var models: [ObjectIdentifier: any Sendable] = [:]
    static let maximumRequirements = 1_024

    @MainActor static func body<M: Music>(of music: M, models: [ObjectIdentifier: any Sendable] = [:]) throws -> M.Body {
        guard models.count <= maximumRequirements else {
            throw SoundCompilationError.invalidPerformance("Too many performance providers")
        }
        var count = 0
        func validate(_ requirement: PerformanceRequirement) throws {
            count += 1
            guard count <= maximumRequirements else {
                throw SoundCompilationError.invalidPerformance("Too many performance requirements")
            }
            guard models[requirement.identifier] != nil else {
                throw SoundCompilationError.missingPerformance(requirement.name)
            }
        }
        if let explicit = music as? any PerformanceRequirementProviding {
            for requirement in explicit.performanceRequirements { try validate(requirement) }
        } else {
            guard !(music is any CustomReflectable) else {
                throw SoundCompilationError.invalidPerformance("CustomReflectable Music must declare performanceRequirements")
            }
            var mirror: Mirror? = Mirror(reflecting: music)
            var depth = 0
            while let current = mirror {
                depth += 1
                guard depth <= 64 else { throw SoundCompilationError.invalidPerformance("Performance declaration hierarchy is too deep") }
                for child in current.children {
                    if let value = child.value as? any _PerformanceRequirement { try validate(value.requirement) }
                }
                mirror = current.superclassMirror
            }
        }
        return $models.withValue(models) { music.body }
    }
}
