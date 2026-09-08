import Observation

/// Tracks model reads during preparation; the host owns scheduling and adoption.
@MainActor
public final class PerformanceObservationSession<Base: Music> {
    private var music: PerformanceMusic<Base>?
    private let compiler: SoundCompiler
    private var generation: UInt64 = 0
    private var notification: (@MainActor @Sendable () -> Void)?

    public init(_ music: PerformanceMusic<Base>, compiler: SoundCompiler = .init(),
                onChange: @escaping @MainActor @Sendable () -> Void) {
        self.music = music
        self.compiler = compiler
        notification = onChange
    }

    public func prepare(revision: UInt64, liveLoop: LiveLoopPolicy? = nil) -> LiveMusicUpdate {
        guard let music, generation < UInt64.max else {
            return .failed(revision: revision, error: .invalidPerformance("Performance observation is inactive"))
        }
        generation += 1
        let expected = generation
        return withObservationTracking {
            do {
                let sound: CompiledSound
                if let liveLoop { sound = try compiler.compile(music, liveLoop: liveLoop) }
                else { sound = try compiler.compile(music) }
                return .prepared(revision: revision, sound: sound)
            } catch let error as SoundCompilationError { return .failed(revision: revision, error: error) }
            catch { return .failed(revision: revision, error: .unexpectedFailure(String(describing: error))) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.music != nil, self.generation == expected else { return }
                self.notification?()
            }
        }
    }

    /// Evaluates one tracked body while preserving the compiler's detailed error type.
    ///
    /// Unlike `prepare(revision:liveLoop:)`, this entry point is used by retained
    /// workers whose diagnostic path must keep `LocatedSoundCompilationError`
    /// provenance intact. The body is evaluated exactly once for the call.
    public func prepareDetailed(liveLoop: LiveLoopPolicy? = nil) throws -> CompiledSound {
        guard let music, generation < UInt64.max else {
            throw SoundCompilationError.invalidPerformance("Performance observation is inactive")
        }
        generation += 1
        let expected = generation
        let result: Result<CompiledSound, any Error> = withObservationTracking {
            do {
                if let liveLoop {
                    return .success(try compiler.compileDetailed(music, liveLoop: liveLoop))
                }
                return .success(try compiler.compileDetailed(music))
            } catch {
                return .failure(error)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.music != nil, self.generation == expected else { return }
                self.notification?()
            }
        }
        return try result.get()
    }

    public func invalidate() {
        music = nil
        notification = nil
    }
}

public extension LiveMusicUpdate {
    @MainActor static func prepare<M: Music>(revision: UInt64, music: PerformanceMusic<M>,
                                            using compiler: SoundCompiler = .init()) -> Self {
        do { return .prepared(revision: revision, sound: try compiler.compile(music)) }
        catch let error as SoundCompilationError { return .failed(revision: revision, error: error) }
        catch { return .failed(revision: revision, error: .unexpectedFailure(String(describing: error))) }
    }
}
