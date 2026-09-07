import SwiftMusic
import XCTest

final class SourceProvenanceTests: XCTestCase {
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

        XCTAssertEqual(compiled.sources.count, 1)
        XCTAssertEqual(
            compiled.sources[0].patternAnchor,
            SoundSourceAnchor(fileID: "Session.swift", line: 20, column: 7)
        )
        XCTAssertEqual(compiled.sources[0].patternText, outer.rawValue)
    }

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
        XCTAssertEqual(
            patternSource.sources[0].patternAnchor,
            SoundSourceAnchor(fileID: "Session.swift", line: 30, column: 5)
        )
        XCTAssertEqual(patternSource.sources[0].patternText, notePattern.rawValue)

        let arraySource = try SoundCompiler().compile(
            Synthesizer(.sine).notes(
                [pitch],
                fileID: "Session.swift",
                line: 40,
                column: 5
            )
        )
        XCTAssertEqual(
            arraySource.sources[0].patternAnchor,
            SoundSourceAnchor(fileID: "Session.swift", line: 40, column: 5)
        )
        XCTAssertNil(arraySource.sources[0].patternText)
    }

    func testAllRestRhythmRetainsSourceProvenanceWithoutEvents() throws {
        let compiled = try SoundCompiler().compile(
            Sample("kick").rhythm(
                try RhythmPattern(validating: "~ ~"),
                fileID: "Session.swift",
                line: 50,
                column: 9
            )
        )

        XCTAssertTrue(compiled.events.isEmpty)
        XCTAssertEqual(
            compiled.sources[0].patternAnchor,
            SoundSourceAnchor(fileID: "Session.swift", line: 50, column: 9)
        )
        XCTAssertEqual(compiled.sources[0].patternText, "~ ~")
    }

    func testPatternStepIndicesFollowTokensAndSurviveCloningTransforms() throws {
        let rhythm = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x ~ x")
        )
        XCTAssertEqual(rhythm.events.map(\.patternStepIndex), [0, 2])

        let notes = try SoundCompiler().compile(
            Synthesizer(.sine).notes("C4 ~ G4")
        )
        XCTAssertEqual(notes.events.map(\.patternStepIndex), [0, 2])

        let transformed = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x ~ x")
                .repeated(2)
                .fast(2)
                .transpose(1)
        )
        XCTAssertEqual(transformed.events.map(\.patternStepIndex), [0, 2, 0, 2])

        let outer = try SoundCompiler().compile(
            Synthesizer(.sine)
                .rhythm("x x")
                .rhythm("x ~ x")
        )
        XCTAssertEqual(outer.events.map(\.patternStepIndex), [0, 0, 2, 2])

        let pitch = try Pitch(midiNote: 60)
        let assigned = try SoundCompiler().compile(
            Synthesizer(.sine).rhythm("x ~ x").notes([pitch])
        )
        XCTAssertTrue(assigned.events.allSatisfy { $0.patternStepIndex == nil })
    }
}
