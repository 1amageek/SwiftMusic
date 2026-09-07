import SwiftMusic
import XCTest

final class LivePatternTests: XCTestCase {
    func testRhythmLiteralDefersInvalidInputUntilCompilation() throws {
        let valid: RhythmPattern = "x ~ x ~"
        XCTAssertEqual(try valid.steps, [true, false, true, false])

        let compiled = try SoundCompiler().compile(Sample("kick").rhythm(valid))
        XCTAssertEqual(compiled.events.map(\.start), [.zero, .half])
        XCTAssertEqual(compiled.extent, .whole)

        let invalid: RhythmPattern = "x ?"
        XCTAssertThrowsError(try SoundCompiler().compile(Sample("kick").rhythm(invalid))) { error in
            XCTAssertEqual(
                error as? SoundCompilationError,
                .invalidRhythm(.invalidToken(token: "?", index: 1))
            )
        }
    }

    func testDynamicRhythmTextStillValidatesEagerly() throws {
        XCTAssertThrowsError(try RhythmPattern(validating: "x ?")) { error in
            XCTAssertEqual(
                error as? RhythmPatternError,
                .invalidToken(token: "?", index: 1)
            )
        }
    }

    func testNoteLiteralExpandsPitchesAndRestsAcrossDefaultCycle() throws {
        let pattern: NotePattern = "C2 ~ Eb2 Bb2"
        let steps = try pattern.steps
        XCTAssertEqual(steps.compactMap { $0?.midiNote }, [36, 39, 46])
        XCTAssertEqual(steps.map { $0 == nil }, [false, true, false, false])

        let compiled = try SoundCompiler().compile(
            Synthesizer(.saw).notes(pattern)
        )
        XCTAssertEqual(compiled.events.map { $0.pitch?.midiNote }, [36, 39, 46])
        XCTAssertEqual(compiled.events.map(\.start), [.zero, .half, try .half.adding(.quarter)])
        XCTAssertEqual(compiled.events.map(\.duration), Array(repeating: .quarter, count: 3))
        XCTAssertEqual(compiled.extent, .whole)
    }

    func testDynamicNoteTextRejectsMalformedAndOutOfRangePitches() throws {
        XCTAssertThrowsError(try NotePattern(validating: "C2 nope")) { error in
            XCTAssertEqual(
                error as? NotePatternError,
                .invalidToken(token: "nope", index: 1)
            )
        }

        let outOfRange: NotePattern = "C-2"
        XCTAssertThrowsError(try SoundCompiler().compile(Synthesizer(.sine).notes(outOfRange))) { error in
            XCTAssertEqual(
                error as? SoundCompilationError,
                .invalidNotes(.pitchOutOfRange(token: "C-2", index: 0))
            )
        }
    }

    func testFailedInitialLiveUpdateHasNoCurrentSoundAndCopiesAreIndependent() throws {
        var state = LiveMusicState()
        let copy = state
        XCTAssertTrue(state.beginUpdate(revision: 0))
        XCTAssertNil(copy.latestRevision)

        let failure = LiveMusicUpdate.prepare(
            revision: 0,
            sound: Sample("kick").rhythm("x ?")
        )
        XCTAssertTrue(state.receive(failure))
        XCTAssertNil(state.currentSound)
        XCTAssertNil(state.pendingSound)
        XCTAssertEqual(state.diagnosticRevision, 0)
        XCTAssertNotNil(state.diagnostic)
    }

    func testLiveStateAcceptsMaximumRevisionOnceAndAdoptsOnlyAtBoundary() throws {
        var state = LiveMusicState()
        let revision = UInt64.max
        XCTAssertTrue(state.beginUpdate(revision: revision))

        let update = LiveMusicUpdate.prepare(revision: revision, sound: Sample("kick"))
        XCTAssertTrue(state.receive(update))
        XCTAssertNil(state.currentSound)
        XCTAssertNotNil(state.pendingSound)

        let adopted = try XCTUnwrap(state.adoptPendingAtBoundary())
        XCTAssertEqual(state.currentSound, adopted)
        XCTAssertEqual(state.currentRevision, revision)
        XCTAssertFalse(state.beginUpdate(revision: revision))
    }
}
