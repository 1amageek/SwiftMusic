/// Synchronous, bounded compilation of a score declaration into immutable events.
public struct ScoreCompiler: Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumDepth: Int
        public let maximumEvents: Int
        public let maximumTracks: Int

        /// Defaults for ordinary interactive score declarations.
        public static let standard = Limits(
            uncheckedMaximumDepth: 64,
            uncheckedMaximumEvents: 10_000,
            uncheckedMaximumTracks: 1_000
        )

        public init(
            maximumDepth: Int,
            maximumEvents: Int,
            maximumTracks: Int
        ) throws {
            guard maximumDepth > 0 else {
                throw LimitsError.nonPositiveMaximumDepth
            }
            guard maximumEvents > 0 else {
                throw LimitsError.nonPositiveMaximumEvents
            }
            guard maximumTracks > 0 else {
                throw LimitsError.nonPositiveMaximumTracks
            }
            self.maximumDepth = maximumDepth
            self.maximumEvents = maximumEvents
            self.maximumTracks = maximumTracks
        }

        private init(
            uncheckedMaximumDepth maximumDepth: Int,
            uncheckedMaximumEvents maximumEvents: Int,
            uncheckedMaximumTracks maximumTracks: Int
        ) {
            self.maximumDepth = maximumDepth
            self.maximumEvents = maximumEvents
            self.maximumTracks = maximumTracks
        }
    }

    public enum LimitsError: Error, Equatable, Sendable {
        case nonPositiveMaximumDepth
        case nonPositiveMaximumEvents
        case nonPositiveMaximumTracks
    }

    public let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public func compile<M: Music>(_ music: M) throws -> CompiledScore {
        try compile(score: music.score)
    }

    public func compile<S: Score>(_ score: S) throws -> CompiledScore {
        try compile(score: score as any Score)
    }

    private func compile(score: any Score) throws -> CompiledScore {
        var context = _ScoreCompilationContext(limits: limits)
        let extent = try context.visit(score: score, depth: 0)
        return context.finish(extent: extent)
    }
}
