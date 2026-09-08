public extension SoundCompiler {
    @MainActor func compile<M: Music>(_ music: PerformanceMusic<M>) throws -> CompiledSound {
        try compile(_PerformanceScope.body(of: music.base, models: music.models))
    }

    @MainActor func compileDetailed<M: Music>(_ music: PerformanceMusic<M>) throws -> CompiledSound {
        try compileDetailed(_PerformanceScope.body(of: music.base, models: music.models))
    }

    @MainActor func compile<M: Music>(_ music: PerformanceMusic<M>, liveLoop policy: LiveLoopPolicy) throws -> CompiledSound {
        try compile(_PerformanceScope.body(of: music.base, models: music.models), liveLoop: policy)
    }

    @MainActor func compileDetailed<M: Music>(_ music: PerformanceMusic<M>, liveLoop policy: LiveLoopPolicy) throws -> CompiledSound {
        try compileDetailed(_PerformanceScope.body(of: music.base, models: music.models), liveLoop: policy)
    }
}
