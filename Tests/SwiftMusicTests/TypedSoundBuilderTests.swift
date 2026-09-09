import Testing
import SwiftMusic

struct TypedSoundBuilderTests {
    @Test(.timeLimit(.minutes(1)))
    func concreteTypesCompileIntoParallelEvents() throws {
        @SoundBuilder func empty() -> EmptySound {}
        @SoundBuilder func single() -> Sample { Sample("kick") }
        @SoundBuilder func pair() -> TupleSound<(Sample, Synthesizer)> {
            Sample("kick")
            Synthesizer(.sine)
        }
        @SoundBuilder func branch(_ first: Bool) -> ConditionalSound<Sample, Synthesizer> {
            if first { Sample("kick") } else { Synthesizer(.sine) }
        }
        @SoundBuilder func optional(_ name: String?) -> Sample? {
            if let name { Sample(name) }
        }
        @SoundBuilder func array() -> ArraySound<Sample> {
            for name in ["a", "b", "c"] { Sample(name) }
        }
        let compiler = SoundCompiler()
        let absent = try compiler.compile(empty())
        #expect(absent.events.isEmpty && absent.sources.isEmpty && absent.tracks.isEmpty)
        #expect(absent.extent == .zero)
        #expect(try compiler.compile(single()).sources.map(\.kind) == [.sample("kick")])
        let parallel = try compiler.compile(pair())
        #expect(parallel.sources.map(\.kind) == [.sample("kick"), .synthesizer(.sine)])
        #expect(parallel.events.map(\.start) == [.zero, .zero])
        #expect(parallel.extent == .quarter)
        #expect(try compiler.compile(branch(true)).sources.map(\.kind) == [.sample("kick")])
        #expect(try compiler.compile(branch(false)).sources.map(\.kind) == [.synthesizer(.sine)])
        #expect(try compiler.compile(optional(nil)).events.isEmpty)
        #expect(try compiler.compile(optional("hat")).sources.map(\.kind) == [.sample("hat")])
        #expect(try compiler.compile(array()).sources.map(\.kind) == [.sample("a"), .sample("b"), .sample("c")])
    }

    @Test(.timeLimit(.minutes(1)))
    func nestedControlFlowPreservesTracksPatternsAndLiveCompilation() throws {
        enum Part { case kick, bass, silent }
        struct Arrangement: Sound {
            let part: Part
            let extra: String?
            var body: some Sound {
                Track("Main") {
                    SoundGroup {
                        switch part {
                        case .kick: Sample("kick").rhythm("x ~ x ~", fileID: "Session.swift", line: 8, column: 1)
                        case .bass: Synthesizer(.sine).notes("C2 ~ Eb2 ~")
                        case .silent: EmptySound()
                        }
                        if let extra { Sample(extra) }
                        for name in ["hat", "clap"] { Sample(name) }
                        if #available(macOS 14, *) { AnySound(Sample("available")) }
                    }
                }
            }
        }
        let compiler = SoundCompiler()
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let kick = try compiler.compile(Arrangement(part: .kick, extra: nil), liveLoop: policy)
        #expect(kick.sources.map(\.kind) == [.sample("kick"), .sample("hat"), .sample("clap"), .sample("available")])
        #expect(kick.tracks.map(\.name) == ["Main"])
        #expect(kick.events.allSatisfy { $0.trackID == 0 })
        #expect(kick.sources.first?.patternAnchor?.line == 8)
        let bass = try compiler.compile(Arrangement(part: .bass, extra: "extra"), liveLoop: policy)
        #expect(bass.sources.first?.kind == .synthesizer(.sine))
        #expect(bass.sources.count == 5)
        let silent = try compiler.compile(Arrangement(part: .silent, extra: nil))
        #expect(silent.sources.count == 3)
        #expect(silent.sources.allSatisfy { $0.kind != .sample("kick") })
    }

    @Test(.timeLimit(.minutes(1)))
    func groupsKeepModifierScopeAndCompilerFailures() throws {
        let group: SoundGroup<TupleSound<(Sample, Sample)>> = SoundGroup {
            Sample("a")
            Sample("b")
        }
        let effect = AudioEffect.reverb(roomSize: 0.5, wet: 0.25)
        let sound = TupleSound((group.effect(effect), Sample("dry")))
        let compiled = try SoundCompiler().compile(sound)
        let effects = compiled.renderNodes.compactMap { node -> Int? in
            if case .effect(let input, let value) = node, value == effect { return input }
            return nil
        }
        let input = try #require(effects.first)
        #expect(effects.count == 1)
        guard case .mix(let inputs) = compiled.renderNodes[input] else {
            Issue.record("The group effect must process the mixed group.")
            return
        }
        #expect(inputs.count == 2)
        #expect(compiled.sources.map(\.kind) == [.sample("a"), .sample("b"), .sample("dry")])
        let limits = try SoundCompiler.Limits(maximumSources: 1)
        #expect(throws: SoundCompilationError.maximumSourcesExceeded(limit: 1)) {
            try SoundCompiler(limits: limits).compile(group)
        }
        let depth = try SoundCompiler.Limits(maximumDepth: 1)
        #expect(throws: SoundCompilationError.maximumDepthExceeded(limit: 1)) {
            try SoundCompiler(limits: depth).compile(AnySound(AnySound(Sample("deep"))))
        }
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(SoundGroup { EmptySound() }.rhythm("invalid"))
        }
    }
}
