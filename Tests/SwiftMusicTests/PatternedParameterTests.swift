import Testing
@testable import SwiftMusic

struct PatternedParameterTests {
    @Test(.timeLimit(.minutes(3)))
    func testGainPatternIntegerFastAndSlowAreDeferredAndExact() throws {
        let fastPattern = try GainPattern(validating: "1 2").fast(2)
        let fast = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain(fastPattern)
        )
        #expect(fast.events.map(\.gain) == [1, 2, 1, 2])

        let slowPattern = try GainPattern(validating: "1 2").slow(2)
        let slow = try SoundCompiler().compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .repeated(2)
                .gain(slowPattern)
        )
        #expect(slow.events.map(\.gain) == [1, 1, 1, 1, 2, 2, 2, 2])

        let zeroFactor: GainPattern = "1"
        #expect {
            try SoundCompiler().compile(Sample("kick").gain(zeroFactor.fast(0)))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.zeroFactor)
        }

        let overflowing: GainPattern = "1"
        #expect {
            try SoundCompiler().compile(
                Sample("kick").gain(overflowing.slow(UInt64.max).slow(2))
            )
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.timingOverflow)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanPatternSamplesAtOnsetsAndOuterPatternWins() throws {
        let first: PanPattern = "-1 1"
        let second: PanPattern = "0 1"
        let sound = Synthesizer(.sine)
            .rhythm("x x", cycle: .whole)
            .pan(first)
            .pan(second)
        let compiled = try SoundCompiler().compile(sound)

        #expect(compiled.events.map(\.pan) == [0, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanPatternSamplesAfterTimeTransformAndPreservesEarlierAssignment() throws {
        let pattern: PanPattern = "-1 1"
        let sampledAfterTime = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .fast(2)
                .pan(pattern)
        )
        #expect(sampledAfterTime.events.map(\.pan) == [-1, -1, -1, -1])

        let assignedBeforeTime = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x", cycle: .whole)
                .pan(pattern)
                .fast(2)
        )
        #expect(assignedBeforeTime.events.map(\.pan) == [-1, 1])
        #expect(assignedBeforeTime.events.map(\.start) == [.zero, .quarter])
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanPatternIntegerFastAndSlowResolveAtExactOnsets() throws {
        let pattern: PanPattern = "-1 1"
        let fast = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .pan(pattern.fast(2))
        )
        #expect(fast.events.map(\.pan) == [-1, 1, -1, 1])

        let slow = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .repeated(2)
                .pan(pattern.slow(2))
        )
        #expect(slow.events.map(\.pan) == [-1, -1, -1, -1, 1, 1, 1, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanPatternDefersLiteralValidationAndRejectsDomainFailures() throws {
        #expect {
            try PanPattern(validating: "")
        } throws: { error in
            error as? PanPatternError == .emptyInput
        }
        #expect {
            try PanPattern(steps: [])
        } throws: { error in
            error as? PanPatternError == .emptyInput
        }

        let outOfRange: PanPattern = "1.5"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).pan(outOfRange))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.outOfRangeValue(token: "1.5", index: 0))
        }

        let nonFinite: PanPattern = "nan"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).pan(nonFinite))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.nonFiniteValue(token: "nan", index: 0))
        }

        let zeroFactor: PanPattern = "0 1"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).pan(zeroFactor.fast(0)))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.zeroFactor)
        }

        let overflowing: PanPattern = "0 1"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).pan(overflowing.slow(UInt64.max).slow(2)))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.timingOverflow)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testPanPatternPreservesNilMetadataForUnmodifiedEvents() throws {
        let plain = try SoundCompiler().compile(Synthesizer(.sine))
        #expect(plain.events.map(\.pan) == [nil])

        let explicitCenter = try SoundCompiler().compile(
            Synthesizer(.sine).pan(try PanPattern(validating: "0"))
        )
        #expect(explicitCenter.events.map(\.pan) == [0])
    }
}
