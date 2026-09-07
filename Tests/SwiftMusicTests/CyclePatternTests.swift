import SwiftMusic
import Testing

struct CyclePatternTests {
    @Test(.timeLimit(.minutes(3)))
    func nestedAlternationUsesFiniteNaturalPeriodAndStableLeafOrder() throws {
        let pattern: RhythmPattern = "<x <~ x>>"
        #expect(try pattern.steps == [true, false, true, true])

        let repeated: RhythmPattern = "x*3 ~"
        #expect(try repeated.steps == [true, true, true, false])
    }

    @Test(.timeLimit(.minutes(3)))
    func noteChordsExpandAdjacentPitchesAndPreserveRests() throws {
        let pattern: NotePattern = "C4,E4 ~ G4"
        #expect(try pattern.steps.map { $0?.midiNote } == [60, 64, nil, 67])
    }

    @Test(.timeLimit(.minutes(3)))
    func locatedFailuresUseUTF8OffsetsAndOperatorOffsets() throws {
        #expect {
            try RhythmPattern(validating: "x é")
        } throws: { error in
            error as? RhythmPatternError == .invalidToken(token: "é", index: 1, offset: 2)
        }
        #expect {
            try RhythmPattern(validating: "x*0")
        } throws: { error in
            error as? RhythmPatternError == .invalidRepetition(token: "x*0", index: 0, offset: 1)
        }
        #expect {
            try RhythmPattern(validating: "<x")
        } throws: { error in
            error as? RhythmPatternError == .unmatchedOpeningAngleBracket(offset: 0)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func locatedPitchFailuresPointAtChordMember() throws {
        #expect {
            try NotePattern(validating: "C4,é2")
        } throws: { error in
            error as? NotePatternError == .invalidToken(token: "é2", index: 0, offset: 3)
        }
    }
}
