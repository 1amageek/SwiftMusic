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

    @MainActor public func compile<M: Music>(_ music: M) throws -> CompiledSound {
        try compile(_PerformanceScope.body(of: music))
    }

    /// Compiles while retaining the declaration anchor for pattern failures.
    @MainActor public func compileDetailed<M: Music>(_ music: M) throws -> CompiledSound {
        try compileDetailed(_PerformanceScope.body(of: music))
    }

    @MainActor public func compile<M: Music>(
        _ music: M,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        try compile(_PerformanceScope.body(of: music), liveLoop: policy)
    }

    /// Compiles a live loop while retaining declaration anchors for pattern failures.
    @MainActor public func compileDetailed<M: Music>(
        _ music: M,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        try compileDetailed(_PerformanceScope.body(of: music), liveLoop: policy)
    }

    public func compile<S: Sound>(_ sound: S) throws -> CompiledSound {
        do {
            return try compileSound(sound, liveLoop: nil)
        } catch let failure as _LocatedCompilationFailure {
            throw mappedCompilationError(failure.error)
        } catch {
            throw mappedCompilationError(error)
        }
    }

    /// Compiles while retaining the declaration anchor for pattern failures.
    public func compileDetailed<S: Sound>(_ sound: S) throws -> CompiledSound {
        do {
            return try compileSound(sound, liveLoop: nil)
        } catch let failure as _LocatedCompilationFailure {
            let underlying = locatedUnderlying(failure.error)
            throw LocatedSoundCompilationError(
                underlying: underlying,
                anchor: failure.anchor,
                utf8Offset: Self.utf8Offset(in: failure.error),
                patternText: failure.patternText
            )
        } catch {
            throw mappedCompilationError(error)
        }
    }

    public func compile<S: Sound>(
        _ sound: S,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        do {
            return try compileSound(sound, liveLoop: policy)
        } catch let failure as _LocatedCompilationFailure {
            throw mappedCompilationError(failure.error)
        } catch {
            throw mappedCompilationError(error)
        }
    }

    /// Compiles a live loop while retaining the declaration anchor for pattern failures.
    public func compileDetailed<S: Sound>(
        _ sound: S,
        liveLoop policy: LiveLoopPolicy
    ) throws -> CompiledSound {
        do {
            return try compileSound(sound, liveLoop: policy)
        } catch let failure as _LocatedCompilationFailure {
            throw LocatedSoundCompilationError(
                underlying: locatedUnderlying(failure.error),
                anchor: failure.anchor,
                utf8Offset: Self.utf8Offset(in: failure.error),
                patternText: failure.patternText
            )
        } catch {
            throw mappedCompilationError(error)
        }
    }

    private func compileSound<S: Sound>(
        _ sound: S,
        liveLoop policy: LiveLoopPolicy?
    ) throws -> CompiledSound {
        var context = _SoundCompilationContext(
            limits: limits,
            capturesLiveProgram: policy != nil
        )
        let fragment = try context.visit(sound, depth: 0)
        if let policy {
            return try context.finishLive(fragment, policy: policy)
        }
        return try context.finish(fragment)
    }

    private static func utf8Offset(in error: Error) -> Int? {
        switch error {
        case let error as RhythmPatternError: error.utf8Offset
        case let error as NotePatternError: error.utf8Offset
        case let error as GainPatternError: error.utf8Offset
        case let error as PanPatternError: error.utf8Offset
        case let error as PitchPatternError: error.utf8Offset
        case let error as CutoffPatternError: error.utf8Offset
        case let error as EnvelopePatternError: error.utf8Offset
        case let error as SampleSelectionPatternError: error.utf8Offset
        case let error as SoundCompilationError:
            switch error {
            case .invalidRhythm(let value): value.utf8Offset
            case .invalidNotes(let value): value.utf8Offset
            case .invalidGainPattern(let value): value.utf8Offset
            case .invalidPanPattern(let value): value.utf8Offset
            case .invalidPitchPattern(let value): value.utf8Offset
            case .invalidCutoffPattern(let value): value.utf8Offset
            case .invalidEnvelopePattern(let value): value.utf8Offset
            case .invalidSampleSelection(let value): value.utf8Offset
            case .unknownSampleKey(_, let offset): offset
            default: nil
            }
        default:
            nil
        }
    }

    private func mappedCompilationError(_ error: Error) -> Error {
        switch error {
        case let error as RhythmTransformError:
            return SoundCompilationError.invalidRhythmTransform(error)
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
        case let error as SoundCompilationError:
            return error
        default:
            // Preserve the source-compatible compile surface for unexpected client errors.
            return error
        }
    }

    private func locatedUnderlying(_ error: Error) -> SoundCompilationError {
        if let mapped = mappedCompilationError(error) as? SoundCompilationError {
            return mapped
        }
        return .unexpectedFailure(String(describing: error))
    }
}
