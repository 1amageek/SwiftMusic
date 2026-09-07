import SwiftMusic
import Testing

struct SourceProvenanceTests {
    @Test(.timeLimit(.minutes(3)))
    func testRhythmAnchorAndTextUseOutermostPatternAndSurviveOtherTransforms() throws {
        let inner = try RhythmPattern(validating: "x x")
        let outer = try RhythmPattern(validating: "x ~ x ~")
        let compiled = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm(inner, fileID: "Session.swift", line: 10, column: 3)
                .gain(0.5)
                .rhythm(outer, fileID: "Session.swift", line: 20, column: 7)
                .transpose(1)
        )

        #expect(compiled.sources.count == 1)
        #expect(compiled.sources[0].patternAnchor == SoundSourceAnchor(fileID: "Session.swift", line: 20, column: 7))
        #expect(compiled.sources[0].patternText == outer.rawValue)
    }

    @Test(.timeLimit(.minutes(3)))
    func testNotePatternsAndArrayNotesCaptureAnchorWithExpectedTextPolicy() throws {
        let pitch = try Pitch(midiNote: 60)
        let notePattern: NotePattern = "C4 ~ E4"
        let patternSource = try SoundCompiler().compile(
            Synthesizer(.sine).notes(
                notePattern,
                fileID: "Session.swift",
                line: 30,
                column: 5
            )
        )
        #expect(patternSource.sources[0].patternAnchor == SoundSourceAnchor(fileID: "Session.swift", line: 30, column: 5))
        #expect(patternSource.sources[0].patternText == notePattern.rawValue)

        let arraySource = try SoundCompiler().compile(
            Synthesizer(.sine).notes(
                [pitch],
                fileID: "Session.swift",
                line: 40,
                column: 5
            )
        )
        #expect(arraySource.sources[0].patternAnchor == SoundSourceAnchor(fileID: "Session.swift", line: 40, column: 5))
        #expect(arraySource.sources[0].patternText == nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func testAllRestRhythmRetainsSourceProvenanceWithoutEvents() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick").rhythm(
                try RhythmPattern(validating: "~ ~"),
                fileID: "Session.swift",
                line: 50,
                column: 9
            )
        )

        #expect(compiled.events.isEmpty)
        #expect(compiled.sources[0].patternAnchor == SoundSourceAnchor(fileID: "Session.swift", line: 50, column: 9))
        #expect(compiled.sources[0].patternText == "~ ~")
    }

    @Test(.timeLimit(.minutes(3)))
    func testPatternStepIndicesFollowTokensAndSurviveCloningTransforms() throws {
        let rhythm = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x ~ x")
        )
        #expect(rhythm.events.map(\.patternStepIndex) == [0, 2])

        let notes = try SoundCompiler().compile(
            Synthesizer(.sine).notes("C4 ~ G4")
        )
        #expect(notes.events.map(\.patternStepIndex) == [0, 2])

        let transformed = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x ~ x")
                .repeated(2)
                .fast(2)
                .transpose(1)
        )
        #expect(transformed.events.map(\.patternStepIndex) == [0, 2, 0, 2])

        let outer = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x")
                .rhythm("x ~ x")
        )
        #expect(outer.events.map(\.patternStepIndex) == [0, 0, 2, 2])

        let pitch = try Pitch(midiNote: 60)
        let assigned = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x ~ x").notes([pitch])
        )
        #expect(assigned.events.allSatisfy { $0.patternStepIndex == nil })
    }
}
