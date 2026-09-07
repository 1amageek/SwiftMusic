import Testing
@testable import SwiftMusic

struct PatternRateTests {
    private func ratio(_ rate: PatternRate) throws -> MusicalTime {
        try rate.resolvedOrError.get()
    }

    private func compile(_ sound: some Sound) throws -> CompiledSound {
        try SoundCompiler().compile(sound)
    }

    @Test(.timeLimit(.minutes(3)))
    func testCanonicalDecimalScientificAndRationalRates() throws {
        let threeHalvesValue: Double = 1.5
        let threeHalves = try PatternRate(validating: threeHalvesValue)
        let expectedThreeHalves = try MusicalTime(numerator: 3, denominator: 2)
        #expect(try ratio(threeHalves) == expectedThreeHalves)

        let explicit = try PatternRate(numerator: 6, denominator: 4)
        #expect(try ratio(explicit) == expectedThreeHalves)

        let scientificValue: Double = 1e-8
        let scientific = try PatternRate(validating: scientificValue)
        let expectedScientific = try MusicalTime(numerator: 1, denominator: 100_000_000)
        #expect(try ratio(scientific) == expectedScientific)
        let largeDecimal = try PatternRate(validating: 1e18)
        let expectedLarge = try MusicalTime(numerator: 1_000_000_000_000_000_000, denominator: 1)
        #expect(try ratio(largeDecimal) == expectedLarge)
        let reducedDecimal = try PatternRate(validating: 1.25e-19)
        let expectedReduced = try MusicalTime(numerator: 1, denominator: 8_000_000_000_000_000_000)
        #expect(try ratio(reducedDecimal) == expectedReduced)

        let ordinaryProduct = try PatternRate(validating: 1.1 * 1.2)
        let expectedProduct = try MusicalTime(numerator: 33, denominator: 25)
        #expect(try ratio(ordinaryProduct) == expectedProduct)
        let chained: GainPattern = "0 1"
        let compiled = try compile(Sample("kick").rhythm("x x x x")
            .gain(chained.fast(1.1).fast(1.2)))
        #expect(compiled.events.map(\.gain) == [0, 0, 1, 1])

        let computedResidue = try PatternRate(validating: 0.1 + 0.2)
        let expectedResidue = try MusicalTime(
            numerator: 7_500_000_000_000_001,
            denominator: 25_000_000_000_000_000
        )
        #expect(try ratio(computedResidue) == expectedResidue)
    }

    @Test(.timeLimit(.minutes(3)))
    func testRateValidationAndDeferredLiteralFailuresRemainTyped() throws {
        #expect {
            try PatternRate(validating: 0.0)
        } throws: { error in
            error as? PatternRateError == .nonPositiveValue
        }
        #expect {
            try PatternRate(numerator: 0, denominator: 1)
        } throws: { error in
            error as? PatternRateError == .nonPositiveValue
        }
        #expect {
            try PatternRate(numerator: 1, denominator: 0)
        } throws: { error in
            error as? PatternRateError == .zeroDenominator
        }
        #expect {
            try PatternRate(validating: -1.0)
        } throws: { error in
            error as? PatternRateError == .nonPositiveValue
        }
        #expect {
            try PatternRate(validating: Double.nan)
        } throws: { error in
            error as? PatternRateError == .nonFiniteValue
        }
        #expect {
            try PatternRate(validating: Double.infinity)
        } throws: { error in
            error as? PatternRateError == .nonFiniteValue
        }
        #expect {
            try PatternRate(validating: Double.leastNonzeroMagnitude)
        } throws: { error in
            error as? PatternRateError == .overflow
        }
        #expect {
            try PatternRate(validating: 1e20)
        } throws: { error in
            error as? PatternRateError == .overflow
        }

        let zero: PatternRate = PatternRate(floatLiteral: 0)
        #expect {
            try compile(Sample("kick").gain(("1" as GainPattern).fast(zero)))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.invalidRate(.nonPositiveValue))
        }

        let negative = PatternRate(floatLiteral: -1.0)
        #expect {
            try compile(Sample("kick").gain(("1" as GainPattern).slow(negative)))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.invalidRate(.nonPositiveValue))
        }

        let nonFinite = PatternRate(floatLiteral: Double.nan)
        #expect {
            try compile(Synthesizer(.sine).pan(("0" as PanPattern).fast(nonFinite)))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.invalidRate(.nonFiniteValue))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testIntegerOverloadAndFractionalLiteralPhaseBoundaries() throws {
        let integer = try compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain(("0 1" as GainPattern).fast(2))
        )
        #expect(integer.events.map(\.gain) == [0, 1, 0, 1])

        let fractionalGain = try compile(
            Sample("kick")
                .rhythm("x x x x", cycle: .whole)
                .gain(("0 1" as GainPattern).fast(1.5))
        )
        #expect(fractionalGain.events.map(\.gain) == [0, 0, 1, 0])

        let fractionalPan = try compile(
            Synthesizer(.sine)
                .rhythm("x x x x", cycle: .whole)
                .pan(("-1 1" as PanPattern).slow(1.5))
        )
        #expect(fractionalPan.events.map(\.pan) == [-1, -1, -1, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func testPhaseCompositionCancelsReciprocalsAndReportsOverflow() throws {
        let largeRate = try PatternRate(
            numerator: UInt64.max,
            denominator: UInt64.max - 1
        )
        let canceled = try compile(
            Sample("kick")
                .gain(("1" as GainPattern).slow(largeRate).fast(largeRate))
        )
        #expect(canceled.events.map(\.gain) == [1])

        let overflowing = ("1" as GainPattern)
            .slow(largeRate)
            .slow(2)
        #expect {
            try compile(Sample("kick").gain(overflowing))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.timingOverflow)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testFirstDeferredPhaseFailureRemainsSticky() throws {
        let invalidRate = PatternRate(floatLiteral: 0)

        let zeroFirst = ("1" as GainPattern)
            .fast(0)
            .fast(invalidRate)
        #expect {
            try compile(Sample("kick").gain(zeroFirst))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(.zeroFactor)
        }

        let invalidFirst = ("1" as PanPattern)
            .fast(invalidRate)
            .slow(0)
        #expect {
            try compile(Synthesizer(.sine).pan(invalidFirst))
        } throws: { error in
            error as? SoundCompilationError == .invalidPanPattern(.invalidRate(.nonPositiveValue))
        }
    }
}
