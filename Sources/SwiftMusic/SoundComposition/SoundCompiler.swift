/// Compiles sound declarations into beat events and an ordered, unrendered audio plan.
public struct SoundCompiler: Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumDepth: Int
        public let maximumEvents: Int
        public let maximumTracks: Int
        public let maximumSources: Int
        public let maximumRenderNodes: Int

        /// Default bounds for an interactive declaration; callers may supply tighter bounds.
        public static let standard = Limits()

        private init() {
            maximumDepth = 64
            maximumEvents = 10_000
            maximumTracks = 1_000
            maximumSources = 1_000
            maximumRenderNodes = 10_000
        }

        public init(
            maximumDepth: Int = 64,
            maximumEvents: Int = 10_000,
            maximumTracks: Int = 1_000,
            maximumSources: Int = 1_000,
            maximumRenderNodes: Int = 10_000
        ) throws {
            guard maximumDepth > 0, maximumEvents > 0, maximumTracks > 0,
                  maximumSources > 0, maximumRenderNodes > 0 else {
                throw SoundCompilationError.invalidParameter("Compiler limits must be positive")
            }
            self.maximumDepth = maximumDepth
            self.maximumEvents = maximumEvents
            self.maximumTracks = maximumTracks
            self.maximumSources = maximumSources
            self.maximumRenderNodes = maximumRenderNodes
        }
    }

    public let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public func compile<M: Music>(_ music: M) throws -> CompiledSound {
        try compile(music.body)
    }

    public func compile<S: Sound>(_ sound: S) throws -> CompiledSound {
        var context = _SoundCompilationContext(limits: limits)
        do {
            let fragment = try context.visit(sound, depth: 0)
            return context.finish(fragment)
        } catch is MusicalTimeError {
            throw SoundCompilationError.timeOverflow
        }
    }
}
