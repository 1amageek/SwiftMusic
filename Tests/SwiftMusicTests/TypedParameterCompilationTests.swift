import SwiftMusic
import Testing

struct TypedParameterCompilationTests {
    private func envelope(_ attack: Double, _ release: Double) throws -> Envelope {
        try Envelope(
            attackSeconds: attack,
            decaySeconds: 0.1,
            sustainLevel: 0.5,
            releaseSeconds: release
        )
    }

    private func time(_ numerator: UInt64, _ denominator: UInt64 = 1) throws -> MusicalTime {
        try MusicalTime(numerator: numerator, denominator: denominator)
    }

    private func livePolicy(maximumBeats: MusicalTime) throws -> LiveLoopPolicy {
        try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: maximumBeats)
    }

    @Test(.timeLimit(.minutes(3)))
    func typedAndTextPatternsSampleTheSameValuesAtPublicOnsets() throws {
        let tight = try envelope(0.01, 0.12)
        let open = try envelope(0.2, 0.6)
        let textPitch = try PitchPattern(validating: "0 1.5 -1 0.5")
        let typedPitch = try PitchPattern(steps: [
            try Semitones(value: 0),
            try Semitones(value: 1.5),
            try Semitones(value: -1),
            try Semitones(value: 0.5)
        ])
        let textCutoff = try CutoffPattern(validating: "400 800 1600 3200")
        let typedCutoff = try CutoffPattern(steps: [
            try Frequency(hertz: 400),
            try Frequency(hertz: 800),
            try Frequency(hertz: 1_600),
            try Frequency(hertz: 3_200)
        ])
        let textEnvelope = try EnvelopePattern("tight open tight open", values: [
            "tight": tight,
            "open": open
        ])
        let typedEnvelope = try EnvelopePattern(steps: [tight, open, tight, open])
        let base = Synthesizer(.sine).notes("C4 C4 C4 C4")

        let text = try SoundCompiler().compile(
            base
                .transpose(textPitch)
                .lowPass(textCutoff, resonanceQ: 1.25, slope: .twentyFour)
                .envelope(textEnvelope)
        )
        let typed = try SoundCompiler().compile(
            base
                .transpose(typedPitch)
                .lowPass(typedCutoff, resonanceQ: 1.25, slope: .twentyFour)
                .envelope(typedEnvelope)
        )

        #expect(text.events.map(\.pitchOffsetSemitones) == typed.events.map(\.pitchOffsetSemitones))
        #expect(text.events.map(\.cutoffHz) == typed.events.map(\.cutoffHz))
        #expect(text.events.compactMap(\.envelope) == typed.events.compactMap(\.envelope))
        #expect(text.sources.map(\.filter) == typed.sources.map(\.filter))
        #expect(text.events.map(\.pitchOffsetSemitones) == [0, 1.5, -1, 0.5])
        #expect(text.events.map(\.cutoffHz) == [400, 800, 1_600, 3_200])
        #expect(text.events.compactMap(\.envelope) == [tight, open, tight, open])
    }

    @Test(.timeLimit(.minutes(3)))
    func fractionalTransposeIsAdditiveAndRejectsMissingOrOutOfRangePitches() throws {
        let first = try PitchPattern(validating: "0.5")
        let second = try PitchPattern(validating: "1.25")
        let additive = try SoundCompiler().compile(
            Synthesizer(.sine)
                .notes("C4 C4")
                .transpose(first)
                .transpose(second)
        )
        #expect(additive.events.map(\.pitchOffsetSemitones) == [1.75, 1.75])

        let missingPitch = try PitchPattern(validating: "1")
        #expect {
            try SoundCompiler().compile(Sample("kick").transpose(missingPitch))
        } throws: { error in
            error as? SoundCompilationError == .missingPitch
        }

        let tooHigh = try PitchPattern(validating: "100")
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).notes("C4").transpose(tooHigh))
        } throws: { error in
            error as? SoundCompilationError == .pitchOutOfRange
        }

        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine)
                    .transpose(try PitchPattern(validating: "60"))
                    .notes("C8")
            )
        } throws: { error in
            error as? SoundCompilationError == .pitchOutOfRange
        }

        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine)
                    .transpose(65)
                    .chord(.power)
            )
        } throws: { error in
            error as? SoundCompilationError == .pitchOutOfRange
        }

        let pitch126 = try Pitch(midiNote: 126)
        let half = try PitchPattern(validating: "0.5")
        let one = try PitchPattern(validating: "1")
        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine)
                    .notes([pitch126])
                    .transpose(half)
                    .transpose(one)
            )
        } throws: { error in
            error as? SoundCompilationError == .pitchOutOfRange
        }

        let allRest: PitchPattern = "~"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).transpose(allRest))
        } throws: { error in
            error as? SoundCompilationError == .invalidPitchPattern(
                .invalidToken(token: "~", index: 0, offset: 0)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func envelopeOrderingClearsStaticOverridesAndRetainsLivePatternClocks() throws {
        let tight = try envelope(0.01, 0.12)
        let open = try envelope(0.2, 0.6)
        let pattern = try EnvelopePattern("tight open", values: [
            "tight": tight,
            "open": open
        ])
        let recurringPattern = try EnvelopePattern("<tight open>", values: [
            "tight": tight,
            "open": open
        ])
        let staticEnvelope = try envelope(0.05, 0.25)
        let base = Synthesizer(.sine).notes("C4 C4")

        let staticAfterPattern = try SoundCompiler().compile(
            base.envelope(pattern).envelope(staticEnvelope)
        )
        #expect(staticAfterPattern.sources[0].envelope == staticEnvelope)
        #expect(staticAfterPattern.events.allSatisfy { $0.envelope == nil })

        let patternAfterStatic = try SoundCompiler().compile(
            base.envelope(staticEnvelope).envelope(pattern)
        )
        #expect(patternAfterStatic.sources[0].envelope == staticEnvelope)
        #expect(patternAfterStatic.events.compactMap(\.envelope) == [tight, open])

        let live = try SoundCompiler().compile(
                Synthesizer(.sine)
                    .rhythm("x")
                .envelope(recurringPattern),
            liveLoop: try livePolicy(maximumBeats: try time(8))
        )
        #expect(live.extent == (try time(8)))
        #expect(live.events.map(\.start) == [.zero, try time(4)])
        #expect(live.events.compactMap(\.envelope) == [tight, open])

        let liveCleared = try SoundCompiler().compile(
                Synthesizer(.sine)
                    .rhythm("x")
                .envelope(recurringPattern)
                .envelope(staticEnvelope),
            liveLoop: try livePolicy(maximumBeats: try time(8))
        )
        #expect(liveCleared.extent == (try time(8)))
        #expect(liveCleared.events.allSatisfy { $0.envelope == nil })
    }

    @Test(.timeLimit(.minutes(3)))
    func cutoffPatternReplacesFilterAndValidatesQ() throws {
        let first = try CutoffPattern(validating: "400")
        let second = try CutoffPattern(validating: "800")
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .notes("C4 C4")
                .lowPass(first, resonanceQ: 1, slope: .twelve)
                .lowPass(second, resonanceQ: 2, slope: .twentyFour)
        )

        #expect(compiled.events.map(\.cutoffHz) == [800, 800])
        #expect(compiled.sources[0].filter?.kind == .lowPass)
        #expect(compiled.sources[0].filter?.resonanceQ == 2)
        #expect(compiled.sources[0].filter?.slope == .twentyFour)

        #expect {
            try SoundCompiler().compile(
                Synthesizer(.sine).lowPass(second, resonanceQ: 0, slope: .twelve)
            )
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter(
                "Source filter Q must be finite and in 0.1...32"
            )
        }

        let allRest: CutoffPattern = "~"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).rhythm("~").lowPass(allRest))
        } throws: { error in
            error as? SoundCompilationError == .invalidCutoffPattern(
                .invalidToken(token: "~", index: 0, offset: 0)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func provenanceAndGeneratorClocksSurviveParameterSampling() throws {
        let pattern: PitchPattern = "0 1"
        let recurringPattern: PitchPattern = "<0 1>"
        let anchored = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x", fileID: "Fixture.swift", line: 17, column: 9)
                .transpose(pattern)
        )
        #expect(anchored.sources[0].patternAnchor == SoundSourceAnchor(
            fileID: "Fixture.swift", line: 17, column: 9
        ))
        #expect(anchored.sources[0].patternText == "x x")
        #expect(anchored.events.map(\.patternStepIndex) == [0, 1])

        let postGenerator = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x").transpose(recurringPattern),
            liveLoop: try livePolicy(maximumBeats: try time(8))
        )
        #expect(postGenerator.extent == (try time(8)))
        #expect(postGenerator.events.map(\.start) == [.zero, try time(4)])
        #expect(postGenerator.events.map(\.pitchOffsetSemitones) == [0, 1])

        let preGenerator = try SoundCompiler().compile(
            Synthesizer(.sine).transpose(recurringPattern).rhythm("x"),
            liveLoop: try livePolicy(maximumBeats: try time(8))
        )
        #expect(preGenerator.extent == .whole)
        #expect(preGenerator.events.map(\.start) == [.zero])
        #expect(preGenerator.events.map(\.pitchOffsetSemitones) == [0])

        let repeatedClosure = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x").repeated(2).transpose(recurringPattern),
            liveLoop: try livePolicy(maximumBeats: try time(8))
        )
        #expect(repeatedClosure.extent == (try time(8)))
        #expect(repeatedClosure.events.map(\.start) == [.zero, try time(4)])
        #expect(repeatedClosure.events.map(\.pitchOffsetSemitones) == [0, 1])
    }
}
