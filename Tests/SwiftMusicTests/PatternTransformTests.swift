import Testing
@testable import SwiftMusic

struct PatternTransformTests {
    @Test(.timeLimit(.minutes(3)))
    func repeatedFitsLocalCyclesAndReducesNaturalPeriod() throws {
        let halfCycle = try MusicalTime(numerator: 1, denominator: 2)
        let rhythm = try RhythmPattern(validating: "x")
            .repeated(2)
            .resolvedTransform(cycle: .whole)

        #expect(rhythm.program.naturalPeriod == 1)
        #expect(rhythm.program.leaves.map(\.token) == ["x", "x"])
        #expect(rhythm.program.leaves.map(\.start) == [.zero, halfCycle])
        #expect(rhythm.program.leaves.map(\.duration) == [halfCycle, halfCycle])
        #expect(try rhythm.period == .whole)

        let alternating = try NotePattern(validating: "<C4 D4>")
            .repeated(2)
            .resolvedTransform(cycle: .whole)

        #expect(alternating.program.naturalPeriod == 1)
        #expect(alternating.program.leaves.map(\.token) == ["C4", "D4"])
        #expect(alternating.program.leaves.map(\.index) == [0, 1])
        #expect(alternating.program.leaves.map(\.start) == [.zero, halfCycle])
        #expect(try alternating.period == .whole)
    }

    @Test(.timeLimit(.minutes(3)))
    func reverseMirrorsEachCycleAndRetainsLexicalIndices() throws {
        let third = try MusicalTime(numerator: 1, denominator: 3)
        let resolved = try NotePattern(validating: "C4 ~ D4")
            .reversed()
            .resolvedTransform(cycle: .whole)

        #expect(resolved.program.leaves.map(\.token) == ["D4", "~", "C4"])
        #expect(resolved.program.leaves.map(\.index) == [2, 1, 0])
        #expect(resolved.program.leaves.map(\.start) == [.zero, third, try third.multiplied(by: 2)])
        #expect(resolved.program.leaves.map(\.duration) == [third, third, third])
    }

    @Test(.timeLimit(.minutes(3)))
    func phaseAndSpeedComposeInDeclarationOrder() throws {
        let beforeSpeed = try NotePattern(validating: "C4 D4")
            .phase(.quarter)
            .fast(2)
            .resolvedTransform(cycle: .whole)
        let afterSpeed = try NotePattern(validating: "C4 D4")
            .fast(2)
            .phase(.quarter)
            .resolvedTransform(cycle: .whole)

        #expect(beforeSpeed.program.leaves.map(\.start) != afterSpeed.program.leaves.map(\.start))
    }

    @Test(.timeLimit(.minutes(3)))
    func allDomainsExposeDeferredTransformsAndTypedFailures() throws {
        let rhythm: RhythmPattern = "x"
        #expect {
            try rhythm.fast(0).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? RhythmPatternError == .zeroFactor
        }

        let notes: NotePattern = "C4"
        #expect {
            try notes.repeated(0).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? NotePatternError == .zeroFactor
        }

        let gain: GainPattern = "1"
        #expect {
            try gain.fast(PatternRate(floatLiteral: 0)).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? GainPatternError == .invalidRate(.nonPositiveValue)
        }

        let pan: PanPattern = "0"
        #expect {
            try pan.slow(PatternRate(floatLiteral: 0)).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? PanPatternError == .invalidRate(.nonPositiveValue)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func transformedRealizationBoundsFailBeforeDomainArraysGrow() throws {
        let rhythm: RhythmPattern = "x"
        #expect {
            try rhythm.repeated(UInt64.max).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? RhythmPatternError == .timingOverflow()
        }

        let gain: GainPattern = "1"
        #expect {
            try gain.repeated(UInt64.max).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? GainPatternError == .timingOverflow()
        }

        let pan: PanPattern = "0"
        #expect {
            try pan.repeated(UInt64.max).resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? PanPatternError == .timingOverflow()
        }

        let chordText = String(repeating: "C4,C4 ", count: 512)
        let notes = try NotePattern(validating: chordText).repeated(2)
        #expect {
            try notes.resolvedTransform(cycle: .whole)
        } throws: { error in
            error as? NotePatternError == .timingOverflow()
        }
    }
}
