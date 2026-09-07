import Testing
import SwiftMusic

struct ModulationEffectCompilationTests {
    @Test(.timeLimit(.minutes(3)))
    func typedFactoriesAndLegacyFilterCasesRemainOrdered() throws {
        let frequency = try Frequency(hertz: 1_000)
        let filter = AudioEffect.filter(kind: .notch, cutoff: frequency, resonance: 0)
        let chorus = AudioEffect.chorus(rate: frequency, depth: 0.25, wet: 0.5)
        let flanger = try AudioEffect.flanger(
            rate: frequency,
            delay: .milliseconds(4),
            depth: .milliseconds(1),
            feedback: -0.2,
            wet: 0.5
        )
        let phaser = AudioEffect.phaser(
            rate: frequency,
            minimum: try Frequency(hertz: 200),
            maximum: try Frequency(hertz: 2_000),
            stages: 4,
            feedback: 0.25,
            wet: 0.5
        )
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .effect(filter)
                .effect(chorus)
                .effect(flanger)
                .effect(phaser)
                .effect(.stereoWidth(0.75))
        )

        #expect(compiled.renderNodes.dropFirst().compactMap { node in
            guard case .effect(_, let effect) = node else { return nil }
            return effect
        } == [filter, chorus, flanger, phaser, .stereoWidth(0.75)])
    }

    @Test(.timeLimit(.minutes(3)))
    func modulationDescriptorsRejectInvalidBounds() throws {
        let frequency = try Frequency(hertz: 1_000)
        let invalidEffects: [AudioEffect] = [
            .flanger(rateHz: 1_000, delaySeconds: 0.001, depthSeconds: 0.001,
                     feedback: 0, wet: 0),
            .flanger(rateHz: 1_000, delaySeconds: 0.001, depthSeconds: 0.002,
                     feedback: 0, wet: 0),
            .phaser(rateHz: 1_000, minimumHz: 2_000, maximumHz: 1_000,
                    stages: 1, feedback: 0, wet: 0),
            .phaser(rateHz: 1_000, minimumHz: 100, maximumHz: 2_000,
                    stages: 33, feedback: 0, wet: 0),
            .phaser(rateHz: 1_000, minimumHz: 100, maximumHz: 2_000,
                    stages: 1, feedback: 1, wet: 0),
            .stereoWidth(-0.1)
        ]
        for effect in invalidEffects {
            #expect(throws: SoundCompilationError.self) {
                try SoundCompiler().compile(Synthesizer(.sine).effect(effect))
            }
        }
        #expect(throws: SoundParameterError.self) {
            try AudioEffect.flanger(
                rate: frequency,
                delay: .seconds(-1),
                depth: .zero,
                feedback: 0,
                wet: 0
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func tremoloLowersToGraphPositionGainAutomationAndZeroIsIdentity() throws {
        let rate = ModulationRate.synchronized(period: .half)
        let tremolo = Synthesizer(.sine).tremolo(
            rate: rate, depth: 0.5, waveform: .sawUp
        )
        let compiled = try SoundCompiler().compile(tremolo)
        guard case .gainAutomation(input: 0, let automation) = compiled.renderNodes.last else {
            Issue.record("Expected a graph-position gain automation node")
            return
        }
        #expect(try automation.value(at: 0) == 0.5)
        #expect(try automation.value(at: 0.5) == 0.75)

        let neutral = try SoundCompiler().compile(
            Synthesizer(.sine).tremolo(rate: rate, depth: 0)
        )
        #expect(neutral.renderNodes == [.source(sourceID: 0)])
    }

    @Test(.timeLimit(.minutes(3)))
    func vibratoUsesOutermostSourceAutomationAndZeroDoesNotRejectSource() throws {
        let rate = ModulationRate.synchronized(period: .whole)
        let vibrato = Synthesizer(.sine).vibrato(
            rate: rate, depth: try Semitones(value: 2), waveform: .sawUp
        )
        let compiled = try SoundCompiler().compile(vibrato)
        let automation = try #require(compiled.sources[0].pitchAutomation)
        #expect(try automation.value(at: 0) == -2)
        #expect(try automation.value(at: 0.5) == 0)

        let neutral = try SoundCompiler().compile(
            Sample("noise").vibrato(rate: rate, depth: try Semitones(value: 0))
        )
        #expect(neutral.sources[0].pitchAutomation == nil)
        let unchanged = try SoundCompiler().compile(vibrato.vibrato(rate: rate, depth: Semitones(value: 0)))
        #expect(unchanged == compiled)
    }

    @Test(.timeLimit(.minutes(3)))
    func synchronizedModulationContributesToLiveWindow() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let sound = Synthesizer(.sine)
            .rhythm("x ~ x ~")
            .tremolo(rate: .synchronized(period: .half), depth: 0.25)
        let compiled = try SoundCompiler().compile(sound, liveLoop: policy)
        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == .whole)
    }

    @Test(.timeLimit(.minutes(3)))
    func continuousAutomationClockIsNotTransformedOrAccumulatedByEventModifiers() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 1, maximumBeats: .whole)
        let replaced = Synthesizer(.sine)
            .vibrato(rate: .synchronized(period: .whole), depth: try Semitones(value: 1))
            .vibrato(rate: .synchronized(period: .half), depth: try Semitones(value: 2))
        let replacedResult = try SoundCompiler().compile(replaced, liveLoop: policy)
        #expect(replacedResult.extent == .half)

        let eventTransformed = Synthesizer(.sine)
            .rhythm("x")
            .tremolo(rate: .synchronized(period: .whole), depth: 0.5)
            .fast(2)
        let eventTransformedResult = try SoundCompiler().compile(eventTransformed, liveLoop: policy)
        #expect(eventTransformedResult.extent == .whole)
    }

    @Test(.timeLimit(.minutes(3)))
    func modulationEffectNodeBoundIsExplicit() throws {
        var sound = Synthesizer(.sine).effect(.stereoWidth(0.5))
        for _ in 0..<31 { sound = sound.effect(.stereoWidth(0.5)) }
        #expect(try SoundCompiler().compile(sound).events.count == 1)
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(sound.effect(.stereoWidth(0.5)))
        }
    }
}
