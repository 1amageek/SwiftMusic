import SwiftMusic
import Testing

struct LivePatternTests {
    @Test(.timeLimit(.minutes(3)))
    func testRhythmLiteralDefersInvalidInputUntilCompilation() throws {
        let valid: RhythmPattern = "x ~ x ~"
        #expect(try valid.steps == [true, false, true, false])

        let compiled = try SoundCompiler().compile(Sample("kick").rhythm(valid))
        #expect(compiled.events.map(\.start) == [.zero, .half])
        #expect(compiled.extent == .whole)

        let invalid: RhythmPattern = "x ?"
        #expect {
            try SoundCompiler().compile(Sample("kick").rhythm(invalid))
        } throws: { error in
            error as? SoundCompilationError == .invalidRhythm(.invalidToken(token: "?", index: 1))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testDynamicRhythmTextStillValidatesEagerly() throws {
        #expect {
            try RhythmPattern(validating: "x ?")
        } throws: { error in
            error as? RhythmPatternError == .invalidToken(token: "?", index: 1)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testNoteLiteralExpandsPitchesAndRestsAcrossDefaultCycle() throws {
        let pattern: NotePattern = "C2 ~ Eb2 Bb2"
        let steps = try pattern.steps
        #expect(steps.compactMap { $0?.midiNote } == [36, 39, 46])
        #expect(steps.map { $0 == nil } == [false, true, false, false])

        let compiled = try SoundCompiler().compile(
            Synthesizer(.saw).notes(pattern)
        )
        #expect(compiled.events.map { $0.pitch?.midiNote } == [36, 39, 46])
        #expect(compiled.events.map(\.start) == [.zero, .half, try .half.adding(.quarter)])
        #expect(compiled.events.map(\.duration) == Array(repeating: .quarter, count: 3))
        #expect(compiled.extent == .whole)
    }

    @Test(.timeLimit(.minutes(3)))
    func testDynamicNoteTextRejectsMalformedAndOutOfRangePitches() throws {
        #expect {
            try NotePattern(validating: "C2 nope")
        } throws: { error in
            error as? NotePatternError == .invalidToken(token: "nope", index: 1)
        }

        let outOfRange: NotePattern = "C-2"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).notes(outOfRange))
        } throws: { error in
            error as? SoundCompilationError == .invalidNotes(.pitchOutOfRange(token: "C-2", index: 0))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testFailedInitialLiveUpdateHasNoCurrentSoundAndCopiesAreIndependent() throws {
        var state = LiveMusicState()
        let copy = state
        let began = state.beginUpdate(revision: 0)
        #expect(began)
        #expect(copy.latestRevision == nil)

        let failure = LiveMusicUpdate.prepare(
            revision: 0,
            sound: Sample("kick").rhythm("x ?")
        )
        let received = state.receive(failure)
        #expect(received)
        #expect(state.currentSound == nil)
        #expect(state.pendingSound == nil)
        #expect(state.diagnosticRevision == 0)
        #expect(state.diagnostic != nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func testLiveStateAcceptsMaximumRevisionOnceAndAdoptsOnlyAtBoundary() throws {
        var state = LiveMusicState()
        let revision = UInt64.max
        let began = state.beginUpdate(revision: revision)
        #expect(began)

        let update = LiveMusicUpdate.prepare(revision: revision, sound: Sample("kick"))
        let received = state.receive(update)
        #expect(received)
        #expect(state.currentSound == nil)
        #expect(state.pendingSound != nil)

        let pending = state.adoptPendingAtBoundary()
        let adopted = try #require(pending)
        #expect(state.currentSound == adopted)
        #expect(state.currentRevision == revision)
        let repeatedBegin = state.beginUpdate(revision: revision)
        #expect(!repeatedBegin)
    }
}
