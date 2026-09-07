@testable import SwiftMusic
import Testing

struct SourceEnvelopeCompilationTests {
    private func envelope(
        attack: Double = 0.01,
        decay: Double = 0.1,
        sustain: Double = 0.5,
        release: Double = 0.2,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
    ) throws -> Envelope {
        try Envelope(
            attackSeconds: attack,
            decaySeconds: decay,
            sustainLevel: sustain,
            releaseSeconds: release,
            attackCurve: attackCurve,
            decayCurve: decayCurve,
            releaseCurve: releaseCurve,
            releaseAnchor: releaseAnchor
        )
    }

    private func time(_ numerator: UInt64, _ denominator: UInt64 = 1) throws -> MusicalTime {
        try MusicalTime(numerator: numerator, denominator: denominator)
    }

    @Test(.timeLimit(.minutes(3)))
    func envelopeCurvesAnchorsAndDurationConstructionValidate() throws {
        let durationEnvelope = try Envelope(
            attack: .milliseconds(5),
            decay: .milliseconds(80),
            sustainLevel: 0.5,
            release: .milliseconds(120),
            attackCurve: .exponential(exponent: 2),
            decayCurve: .linear,
            releaseCurve: .exponential(exponent: 0.5),
            releaseAnchor: .eventEnd
        )
        #expect(durationEnvelope.attackSeconds == 0.005)
        #expect(durationEnvelope.releaseSeconds == 0.12)
        #expect(durationEnvelope.attackCurve == .exponential(exponent: 2))
        #expect(durationEnvelope.releaseCurve == .exponential(exponent: 0.5))
        #expect(durationEnvelope.releaseAnchor == .eventEnd)

        let defaults = try envelope()
        #expect(defaults.attackCurve == .linear)
        #expect(defaults.decayCurve == .linear)
        #expect(defaults.releaseCurve == .linear)
        #expect(defaults.releaseAnchor == .gateEnd)

        #expect {
            try envelope(attackCurve: .exponential(exponent: 0))
        } throws: { error in
            error as? SoundParameterError == .invalidValue("envelope curve exponent")
        }
        #expect {
            try envelope(releaseCurve: .exponential(exponent: .infinity))
        } throws: { error in
            error as? SoundParameterError == .invalidValue("envelope curve exponent")
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func sourceModulationReplacesDescriptorsAndRetainsLiveSourceState() throws {
        let firstAmplitude = try envelope(attack: 0.01)
        let secondAmplitude = try envelope(attack: 0.02)
        let firstPitch = try envelope(attack: 0.03)
        let secondPitch = try envelope(attack: 0.04)
        let firstFilter = try envelope(attack: 0.05)
        let secondFilter = try envelope(attack: 0.06)
        let firstDepth = try Semitones(value: 2)
        let secondDepth = try Semitones(value: -3)

        let sound = Synthesizer(.sine)
            .envelope(firstAmplitude)
            .envelope(secondAmplitude)
            .pitchEnvelope(firstPitch, depth: firstDepth)
            .pitchEnvelope(secondPitch, depth: secondDepth)
            .filterEnvelope(firstFilter, depth: firstDepth)
            .filterEnvelope(secondFilter, depth: secondDepth)
        let compiled = try SoundCompiler().compile(sound)

        #expect(compiled.sources[0].envelope == secondAmplitude)
        #expect(compiled.sources[0].pitchEnvelope?.envelope == secondPitch)
        #expect(compiled.sources[0].pitchEnvelope?.depth == secondDepth)
        #expect(compiled.sources[0].filterEnvelope?.envelope == secondFilter)
        #expect(compiled.sources[0].filterEnvelope?.depth == secondDepth)

        let live = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x")
                .envelope(secondAmplitude)
                .pitchEnvelope(secondPitch, depth: secondDepth)
                .filterEnvelope(secondFilter, depth: secondDepth),
            liveLoop: try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: try time(4))
        )
        #expect(live.extent == .whole)
        #expect(live.sources[0].pitchEnvelope?.depth == secondDepth)
        #expect(live.sources[0].filterEnvelope?.depth == secondDepth)
        #expect(live.sources[0].envelope == secondAmplitude)
    }

    @Test(.timeLimit(.minutes(3)))
    func fixedAndPatternedFiltersExposeKindsReplaceCutoffsAndRetainPriorClock() throws {
        let finitePattern = try CutoffPattern(validating: "400 800")
        let finite = try SoundCompiler().compile(
            Synthesizer(.sine)
                .notes("C4 C4")
                .lowPass(finitePattern, resonanceQ: 1, slope: .twelve)
                .highPass(try Frequency(hertz: 1_200), resonanceQ: 2, slope: .twentyFour)
        )
        #expect(finite.sources[0].filter?.kind == .highPass)
        #expect(finite.sources[0].filter?.resonanceQ == 2)
        #expect(finite.sources[0].filter?.slope == .twentyFour)
        #expect(finite.events.map(\.cutoffHz) == [1_200, 1_200])

        let highPattern = try CutoffPattern(validating: "400 800")
        let high = try SoundCompiler().compile(
            Synthesizer(.sine).notes("C4 C4").highPass(highPattern)
        )
        #expect(high.sources[0].filter?.kind == .highPass)
        #expect(high.events.map(\.cutoffHz) == [400, 800])

        let band = try SoundCompiler().compile(
            Synthesizer(.sine)
                .notes("C4 C4")
                .bandPass(try Frequency(hertz: 1_600), resonanceQ: 0.1)
        )
        #expect(band.sources[0].filter?.kind == .bandPass)
        #expect(band.sources[0].filter?.resonanceQ == 0.1)
        #expect(band.events.map(\.cutoffHz) == [1_600, 1_600])

        let recurringPattern = try CutoffPattern(validating: "<400 800>")
        let live = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x")
                .lowPass(recurringPattern)
                .highPass(try Frequency(hertz: 1_200)),
            liveLoop: try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: try time(8))
        )
        #expect(live.extent == (try time(8)))
        #expect(live.events.map(\.start) == [.zero, try time(4)])
        #expect(live.events.map(\.cutoffHz) == [1_200, 1_200])
        #expect(live.sources[0].filter?.kind == .highPass)
    }

    @Test(.timeLimit(.minutes(3)))
    func filterValidationRunsForEmptyEventsAndRejectsUnsupportedBounds() throws {
        let cutoff = try Frequency(hertz: 800)
        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine).lowPass(cutoff, resonanceQ: 0.099)
            )
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter(
                "Source filter Q must be finite and in 0.1...32"
            )
        }
        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine).highPass(cutoff, resonanceQ: 32.001)
            )
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter(
                "Source filter Q must be finite and in 0.1...32"
            )
        }

        #expect {
            try SoundCompiler().compile(
                Sample("kick").rhythm("~").bandPass(cutoff, resonanceQ: .nan)
            )
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter(
                "Source filter Q must be finite and in 0.1...32"
            )
        }

        let empty = try SoundCompiler().compile(
            Sample("kick").rhythm("~").bandPass(cutoff, resonanceQ: 1)
        )
        #expect(empty.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(3)))
    func notchSourceFilterIsRejectedAsTypedFailure() throws {
        #expect {
            try SourceFilter(kind: .notch, resonanceQ: 1, slope: .twelve)
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter(
                "Notch source filter is unsupported"
            )
        }
    }
}
