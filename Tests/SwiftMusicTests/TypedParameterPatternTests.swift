import Testing
@testable import SwiftMusic

struct TypedParameterPatternTests {
    private func envelope(_ attack: Double, _ release: Double) throws -> Envelope {
        try Envelope(
            attackSeconds: attack,
            decaySeconds: 0.1,
            sustainLevel: 0.5,
            releaseSeconds: release
        )
    }

    @Test(.timeLimit(.minutes(3)))
    func pitchAndCutoffPatternsSupportTextTypedValuesAndTransforms() throws {
        let pitch: PitchPattern = "-2 <0 7>"
        let pitchResolved = try pitch.repeated(2).resolvedTransform(cycle: .whole)
        let pitchValues = try pitchResolved.program.leaves.map { try pitch.value(at: $0).value }
        #expect(pitchValues == [-2, 0, -2, 7])
        #expect(try pitch.steps.map(\.value) == [-2, 0, -2, 7])

        let typedPitch = try PitchPattern(steps: [
            try Semitones(value: -1.5),
            try Semitones(value: 2)
        ])
        #expect(try typedPitch.steps.map(\.value) == [-1.5, 2])
        #expect(try typedPitch.reversed().resolvedTransform(cycle: .whole).program.leaves.count == 2)

        let cutoff: CutoffPattern = "400 <800 1600>"
        let cutoffResolved = try cutoff.resolvedTransform(cycle: .whole)
        let cutoffValues = try cutoffResolved.program.leaves.map { try cutoff.value(at: $0).hertz }
        #expect(cutoffValues == [400, 800, 400, 1600])

        let typedCutoff = try CutoffPattern(steps: [
            try Frequency(hertz: 200),
            try Frequency(hertz: 2_000)
        ])
        #expect(try typedCutoff.steps.map(\.hertz) == [200, 2_000])
    }

    @Test(.timeLimit(.minutes(3)))
    func envelopePatternResolvesNamedAlternativesAndRejectsRest() throws {
        let tight = try envelope(0.01, 0.12)
        let open = try envelope(0.2, 0.6)
        let pattern = try EnvelopePattern("tight <open tight> tight*2", values: [
            "tight": tight,
            "open": open
        ])

        #expect(try pattern.steps == [tight, open, tight, tight, tight, tight, tight, tight])
        let resolved = try pattern.reversed().resolvedTransform(cycle: .whole)
        #expect(resolved.program.leaves.count == 8)

        #expect {
            try EnvelopePattern("missing", values: ["known": tight]).steps
        } throws: { error in
            error as? EnvelopePatternError == .unknownKey(token: "missing", index: 0, offset: 0)
        }

        #expect {
            try EnvelopePattern("tight ~", values: ["tight": tight]).steps
        } throws: { error in
            error as? EnvelopePatternError == .invalidToken(token: "~", index: 1, offset: 6)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func notationFailuresRetainUTF8OffsetsAndTypedFailuresHaveNoSourceOffset() throws {
        #expect {
            try PitchPattern(validating: "é")
        } throws: { error in
            error as? PitchPatternError == .invalidToken(token: "é", index: 0, offset: 0)
        }
        #expect {
            try CutoffPattern(validating: "é")
        } throws: { error in
            error as? CutoffPatternError == .invalidToken(token: "é", index: 0, offset: 0)
        }

        let invalidCutoff: CutoffPattern = "0"
        #expect {
            try invalidCutoff.steps
        } throws: { error in
            error as? CutoffPatternError == .nonPositiveValue(token: "0", index: 0, offset: 0)
        }

        #expect {
            try PitchPattern(steps: [])
        } throws: { error in
            guard let error = error as? PitchPatternError else { return false }
            return error == .emptyTypedValues && error.utf8Offset == nil
        }

        let invalidRate: PitchPattern = "0"
        #expect {
            try invalidRate.fast(PatternRate(floatLiteral: 0)).resolvedTransform(cycle: .whole)
        } throws: { error in
            guard let error = error as? PitchPatternError else { return false }
            return error == .invalidRate(.nonPositiveValue) && error.utf8Offset == nil
        }
    }
}
