/// A plan preparation result. Audio resources still require preparation by the host backend.
public enum LiveMusicUpdate: Sendable, Equatable {
    case prepared(revision: UInt64, sound: CompiledSound)
    case failed(revision: UInt64, error: SoundCompilationError)

    public var revision: UInt64 {
        switch self {
        case .prepared(let revision, _), .failed(let revision, _): revision
        }
    }

    public static func prepare<M: Music>(
        revision: UInt64,
        music: M,
        using compiler: SoundCompiler = .init()
    ) -> Self {
        prepare(revision: revision, sound: music.body, using: compiler)
    }

    public static func prepare<S: Sound>(
        revision: UInt64,
        sound: S,
        using compiler: SoundCompiler = .init()
    ) -> Self {
        do {
            return .prepared(revision: revision, sound: try compiler.compile(sound))
        } catch let error as SoundCompilationError {
            return .failed(revision: revision, error: error)
        } catch {
            return .failed(revision: revision, error: .unexpectedFailure(String(describing: error)))
        }
    }
}
