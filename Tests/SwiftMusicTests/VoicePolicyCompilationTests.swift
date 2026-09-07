import SwiftMusic
import Testing

struct VoicePolicyCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func policyAndChokeReplaceMetadataWithoutChangingCompiledGraph() throws {
        let compiler = SoundCompiler()
        let baseline = try compiler.compile(Synthesizer(.sine).notes("C4 D4"))
        let configured = try compiler.compile(
            Synthesizer(.sine)
                .notes("C4 D4")
                .voicePolicy(.monophonic)
                .voicePolicy(.polyphonic(limit: 4, stealing: .quietest))
                .chokeGroup("  lead  ")
        )

        #expect(configured.events == baseline.events)
        #expect(configured.tracks == baseline.tracks)
        #expect(configured.renderNodes == baseline.renderNodes)
        #expect(configured.rootNodeIDs == baseline.rootNodeIDs)
        #expect(configured.extent == baseline.extent)
        #expect(configured.sources.count == 1)
        #expect(configured.sources[0].voicePolicy == .polyphonic(limit: 4, stealing: .quietest))
        #expect(configured.sources[0].chokeGroup == "lead")
    }

    @Test(.timeLimit(.minutes(3)))
    func outerPolicyAndChokeReplaceInnerValues() throws {
        let sound = try Synthesizer(.sine)
            .voicePolicy(.polyphonic(limit: 3, stealing: .quietest))
            .chokeGroup("inner")
            .voicePolicy(.monophonic)
            .chokeGroup(" outer ")
        let compiled = try SoundCompiler().compile(sound)

        #expect(compiled.sources[0].voicePolicy == .monophonic)
        #expect(compiled.sources[0].chokeGroup == "outer")
    }

    @Test(.timeLimit(.minutes(3)))
    func policiesValidateBoundsAndEmptySubtrees() throws {
        let compiler = SoundCompiler()
        let empty = Track("empty") {}
        let invalidLow = empty.voicePolicy(.polyphonic(limit: 0, stealing: .oldest))
        #expect(throws: SoundParameterError.invalidVoices) {
            try compiler.compile(invalidLow)
        }
        let invalidHigh = empty.voicePolicy(
            .polyphonic(limit: SoundCompiler.Limits.standard.maximumEvents + 1, stealing: .oldest)
        )
        #expect(throws: SoundParameterError.invalidVoices) {
            try compiler.compile(invalidHigh)
        }
        #expect(throws: SoundParameterError.invalidValue("chokeGroup")) {
            try empty.chokeGroup(" \n\t ")
        }

        let validEmpty = try empty.chokeGroup(" hats ")
        let compiled = try compiler.compile(validEmpty)
        #expect(compiled.sources.isEmpty)
        #expect(compiled.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(3)))
    func voiceMetadataDoesNotChangeLiveRecurrence() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let baselineSound = Synthesizer(.sine).rhythm("x ~ x ~")
        let configuredSound = try baselineSound
            .voicePolicy(.polyphonic(limit: 2, stealing: .oldest))
            .chokeGroup("lead")
        let compiler = SoundCompiler()
        let baseline = try compiler.compile(baselineSound, liveLoop: policy)
        let configured = try compiler.compile(configuredSound, liveLoop: policy)

        #expect(configured.events == baseline.events)
        #expect(configured.extent == baseline.extent)
        #expect(configured.tracks == baseline.tracks)
        #expect(configured.renderNodes == baseline.renderNodes)
        #expect(configured.rootNodeIDs == baseline.rootNodeIDs)
        #expect(configured.playbackMode == baseline.playbackMode)
        #expect(configured.sources[0].voicePolicy == .polyphonic(limit: 2, stealing: .oldest))
        #expect(configured.sources[0].chokeGroup == "lead")
    }
}
