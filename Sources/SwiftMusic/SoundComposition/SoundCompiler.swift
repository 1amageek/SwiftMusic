/// Compiles sound declarations into beat events and an ordered, unrendered audio plan.
public struct SoundCompiler: Sendable {
    public struct Limits: Sendable, Equatable {
        public let maximumDepth: Int
        public let maximumEvents: Int
        public let maximumTracks: Int
        public let maximumSources: Int
        public let maximumRenderNodes: Int
        public let maximumBuses: Int

        /// Default bounds for an interactive declaration; callers may supply tighter bounds.
        public static let standard = Limits()

        private init() {
            maximumDepth = 64
            maximumEvents = 10_000
            maximumTracks = 1_000
            maximumSources = 1_000
            maximumRenderNodes = 10_000
            maximumBuses = 32
        }

        public init(
            maximumDepth: Int = 64,
            maximumEvents: Int = 10_000,
            maximumTracks: Int = 1_000,
            maximumSources: Int = 1_000,
            maximumRenderNodes: Int = 10_000,
            maximumBuses: Int = 32
        ) throws {
            guard maximumDepth > 0, maximumEvents > 0, maximumTracks > 0,
                  maximumSources > 0, maximumRenderNodes > 0, maximumBuses > 0 else {
                throw SoundCompilationError.invalidParameter("Compiler limits must be positive")
            }
            self.maximumDepth = maximumDepth
            self.maximumEvents = maximumEvents
            self.maximumTracks = maximumTracks
            self.maximumSources = maximumSources
            self.maximumRenderNodes = maximumRenderNodes
            self.maximumBuses = maximumBuses
        }
    }

    public let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public func compile<M: Music>(_ music: M) throws -> CompiledSound {
        try compile(music.body)
    }

    public func compile<M: Music>(
        _ music: M,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        try compile(music.body, liveLoop: policy)
    }

    public func compile<S: Sound>(_ sound: S) throws -> CompiledSound {
        try compileSound(sound, liveLoop: nil)
    }

    public func compile<S: Sound>(
        _ sound: S,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        try compileSound(sound, liveLoop: policy)
    }

    private func compileSound<S: Sound>(
        _ sound: S,
        liveLoop policy: LiveLoopPolicy?
    ) throws -> CompiledSound {
        var context = _SoundCompilationContext(
            limits: limits,
            capturesLiveProgram: policy != nil
        )
        do {
            let fragment = try context.visit(sound, depth: 0)
            if let policy {
                return try context.finishLive(fragment, policy: policy)
            }
            return try context.finish(fragment)
        } catch {
            throw mappedCompilationError(error)
        }
    }

    private func mappedCompilationError(_ error: Error) -> Error {
        switch error {
        case let error as RhythmPatternError:
            return SoundCompilationError.invalidRhythm(error)
        case let error as NotePatternError:
            return SoundCompilationError.invalidNotes(error)
        case let error as GainPatternError:
            return SoundCompilationError.invalidGainPattern(error)
        case let error as PanPatternError:
            return SoundCompilationError.invalidPanPattern(error)
        case let error as PitchPatternError:
            return SoundCompilationError.invalidPitchPattern(error)
        case let error as CutoffPatternError:
            return SoundCompilationError.invalidCutoffPattern(error)
        case let error as EnvelopePatternError:
            return SoundCompilationError.invalidEnvelopePattern(error)
        case let error as SampleSelectionPatternError:
            return SoundCompilationError.invalidSampleSelection(error)
        case let error as BusRoutingError:
            return SoundCompilationError.invalidBusRouting(error)
        case is MusicalTimeError:
            return SoundCompilationError.timeOverflow
        default:
            return error
        }
    }
}
