import SwiftMusic
import Testing

struct NestedGainPatternTests {
    @Test(.timeLimit(.minutes(3)))
    func testNestedRhythmUsesExactLeafDurationsAndIndices() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick").rhythm("[x ~] x", cycle: .whole)
        )

        #expect(compiled.events.map(\.start) == [.zero, .half])
        #expect(compiled.events.map(\.duration) == [.quarter, .half])
        #expect(compiled.events.map(\.patternStepIndex) == [0, 2])
        #expect(compiled.sources[0].patternText == "[x ~] x")
    }

    @Test(.timeLimit(.minutes(3)))
    func testNestedNotesPreserveRestsAndUseDepthFirstIndices() throws {
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine).notes("[C4 ~] [D4 E4]", cycle: .whole)
        )

        #expect(compiled.events.map(\.start) == [.zero, .half, try .half.adding(.quarter)])
        #expect(compiled.events.map(\.duration) == Array(repeating: .quarter, count: 3))
        #expect(compiled.events.map { $0.pitch?.midiNote } == [60, 62, 64])
        #expect(compiled.events.map(\.patternStepIndex) == [0, 2, 3])
    }

    @Test(.timeLimit(.minutes(3)))
    func testNestedSyntaxFailuresAndBoundsAreTyped() throws {
        let emptyGroup: RhythmPattern = "[]"
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(emptyGroup))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.emptyGroup(offset: 0))
        }

        let unmatched: RhythmPattern = "[x"
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(unmatched))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.unmatchedOpeningBracket(offset: 0))
        }

        let tooDeep = RhythmPattern(stringLiteral: String(repeating: "[", count: 33) + "x")
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(tooDeep))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.nestingTooDeep(limit: 32, offset: 32))
        }

        let tooManyLeaves = RhythmPattern(stringLiteral: String(repeating: "x ", count: 1_025))
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(tooManyLeaves))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.tooManyLeaves(limit: 1_024, offset: 2_048))
        }

        let tooLong = RhythmPattern(stringLiteral: String(repeating: "x", count: 65 * 1024 + 1))
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(tooLong))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.inputTooLong(limit: 64 * 1024, offset: 64 * 1024))
        }

        #expect {
            try RhythmPattern(steps: Array(repeating: true, count: 1_025))
        } throws: { error in
            error as? RhythmPatternError == .tooManyLeaves(limit: 1_024, offset: 0)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testGainPatternSamplesExactCycleBoundariesAndStacks() throws {
        let repeated = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain("[1 0.5]")
        )
        #expect(repeated.events.map(\.gain) == [1, 1, 0.5, 0.5])

        let stacked = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .gain("2 0.5")
                .gain("0.5 2")
        )
        #expect(stacked.events.map(\.gain) == [1, 1])

        let transformedAfterGain = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .gain("1 2")
                .fast(2)
        )
        #expect(transformedAfterGain.events.map(\.gain) == [1, 2])

        let transformedBeforeGain = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .fast(2)
                .gain("1 2")
        )
        #expect(transformedBeforeGain.events.map(\.gain) == [1, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func testGainPatternRepeatsAcrossCyclesWithUnequalEventCount() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x", cycle: .whole)
                .repeated(3)
                .gain("[1 0.5 0.25]")
        )

        #expect(compiled.events.map(\.start) == [
            .zero, .half, .whole,
            try .whole.adding(.half), try .whole.adding(.whole),
            try .whole.adding(.whole).adding(.half)
        ])
        #expect(compiled.events.map(\.gain) == [1, 0.5, 1, 0.5, 1, 0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func testGainPatternAllowsZeroAndRejectsInvalidOrNonfiniteValues() throws {
        let silent = try SoundCompiler().compile(
            Sample("kick").rhythm("x x", cycle: .whole).gain("0 1")
        )
        #expect(silent.events.map(\.gain) == [0, 1])

        let invalidRest: GainPattern = "1 ~"
        #expect {
            try SoundCompiler().compile(Sample("kick").gain(invalidRest))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.invalidToken(token: "~", index: 1, offset: 2))
        }

        let negative: GainPattern = "-1"
        #expect {
            try SoundCompiler().compile(Sample("kick").gain(negative))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.negativeValue(token: "-1", index: 0, offset: 0))
        }

        let nonfinite: GainPattern = "nan"
        #expect {
            try SoundCompiler().compile(Sample("kick").gain(nonfinite))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.nonFiniteValue(token: "nan", index: 0, offset: 0))
        }

        let overflow: GainPattern = "1e308"
        #expect {
            try SoundCompiler().compile(Sample("kick").gain(overflow).gain(overflow))
        } throws: { error in
            guard case .invalidParameter = error as? SoundCompilationError else {
                Issue.record("Expected a finite stacked gain product")
                return false
            }
            return true
        }

        let scalar = try SoundCompiler().compile(Sample("kick").gain(0.5))
        #expect(scalar.events.map(\.gain) == [1])
        #expect(scalar.renderNodes == [.source(sourceID: 0), .gain(input: 0, value: 0.5)])
    }
}
