import SwiftMusic
import XCTest

final class LiveDSLIntegrationTests: XCTestCase {
    func testPatternBoundariesAndCompilerLimitsRemainExplicitFailures() throws {
        let endpoints: NotePattern = "C-1 G9 B#3 Cb4 c#4 db4"
        XCTAssertEqual(try endpoints.steps.map { $0?.midiNote }, [0, 127, 60, 59, 61, 61])
        for text in ["", "C+4", "C#", "C4junk", "C♯4", "C999999999999999999999999999", "G#9"] {
            XCTAssertThrowsError(try NotePattern(text))
        }
        let dynamicRhythm: String = "x invalid"
        XCTAssertThrowsError(try RhythmPattern(dynamicRhythm))
        XCTAssertThrowsError(try SoundCompiler().compile(Track("empty") {}.notes("invalid")))
        XCTAssertThrowsError(try SoundCompiler().compile(Track("empty") {}.rhythm("invalid")))

        let rests = try SoundCompiler().compile(Synthesizer(.sine).notes("C2 ~ ~ ~", cycle: .half))
        XCTAssertEqual(rests.events.count, 1)
        XCTAssertEqual(rests.events.first?.duration, .eighth)
        XCTAssertEqual(rests.extent, .half)
        let allRests = try SoundCompiler().compile(Synthesizer(.sine).notes("~ ~"))
        XCTAssertTrue(allRests.events.isEmpty)
        XCTAssertEqual(allRests.extent, .whole)

        let compiler = SoundCompiler(limits: try .init(maximumEvents: 3))
        XCTAssertThrowsError(try compiler.compile(Synthesizer(.sine).notes("C2 D2 E2 F2"))) {
            XCTAssertEqual($0 as? SoundCompilationError, .maximumEventsExceeded(limit: 3))
        }
    }

    func testFailedEditPreservesAdoptedSoundAndRecoveryWaitsForBoundary() throws {
        var state = LiveMusicState()
        XCTAssertTrue(state.beginUpdate(revision: 0))
        XCTAssertTrue(state.receive(.prepare(revision: 0, sound: Sample("kick").rhythm("x ~ x ~"))))
        XCTAssertNil(state.currentSound)
        let first = try XCTUnwrap(state.adoptPendingAtBoundary())
        XCTAssertEqual(first.events.map(\.start), [.zero, .half])

        XCTAssertTrue(state.beginUpdate(revision: 1))
        XCTAssertTrue(state.receive(.prepare(revision: 1, sound: Sample("kick").rhythm("x ?"))))
        XCTAssertNotNil(state.diagnostic)
        XCTAssertEqual(state.diagnosticRevision, 1)
        XCTAssertNil(state.pendingSound)
        XCTAssertNil(state.adoptPendingAtBoundary())
        XCTAssertEqual(state.currentSound, first)
        XCTAssertEqual(state.currentRevision, 0)

        XCTAssertTrue(state.beginUpdate(revision: 2))
        XCTAssertTrue(state.receive(.prepare(revision: 2, sound: Sample("kick").rhythm("~ x ~ x"))))
        XCTAssertNil(state.diagnostic)
        XCTAssertEqual(state.currentSound, first)
        let next = try XCTUnwrap(state.adoptPendingAtBoundary())
        XCTAssertEqual(next.events.map(\.start), [.quarter, try .half.adding(.quarter)])
        XCTAssertEqual(state.currentRevision, 2)
        XCTAssertNil(state.adoptPendingAtBoundary())
    }

    func testNewEditInvalidatesPendingAndRejectsOlderPreparationCompletions() throws {
        var state = LiveMusicState()
        XCTAssertTrue(state.beginUpdate(revision: 0))
        XCTAssertTrue(state.receive(.prepare(revision: 0, sound: Synthesizer(.sine).notes("C2"))))
        let initial = try XCTUnwrap(state.adoptPendingAtBoundary())

        XCTAssertTrue(state.beginUpdate(revision: 1))
        let oldCompletion = LiveMusicUpdate.prepare(revision: 1, sound: Synthesizer(.sine).notes("D2"))
        XCTAssertTrue(state.receive(oldCompletion))
        XCTAssertTrue(state.beginUpdate(revision: 2))
        XCTAssertNil(state.pendingSound)
        XCTAssertFalse(state.receive(oldCompletion))
        XCTAssertNil(state.adoptPendingAtBoundary())
        XCTAssertEqual(state.currentSound, initial)

        let failure = LiveMusicUpdate.prepare(revision: 2, sound: Synthesizer(.sine).notes("C2 nope"))
        XCTAssertTrue(state.receive(failure))
        XCTAssertFalse(state.receive(failure))
        XCTAssertFalse(state.beginUpdate(revision: 1))
        XCTAssertEqual(state.diagnosticRevision, 2)
        XCTAssertEqual(state.currentSound, initial)

        XCTAssertTrue(state.beginUpdate(revision: 3))
        let delayed = LiveMusicUpdate.prepare(revision: 3, sound: Sample("old"))
        XCTAssertTrue(state.beginUpdate(revision: 4))
        XCTAssertFalse(state.receive(delayed))
        XCTAssertEqual(state.preparingRevision, 4)
        XCTAssertEqual(state.currentSound, initial)
    }

    func testPhilosophyExampleProducesParallelDrumsAndTimedBass() throws {
        struct Groove: Sound {
            var body: some Sound {
                Sample("kick")
                    .rhythm("x ~ x ~")
                    .gain(0.9)

                Synthesizer(.saw)
                    .notes("C2 Eb2 G2 Bb2")
                    .gain(0.5)
            }
        }

        struct Song: Music {
            var body: some Sound { Groove() }
        }

        let result = try SoundCompiler().compile(Song())
        let drums = result.events.filter { $0.sourceID == 0 }
        let bass = result.events.filter { $0.sourceID == 1 }
        XCTAssertEqual(drums.map(\.start), [.zero, .half])
        XCTAssertEqual(bass.map { $0.pitch?.midiNote }, [36, 39, 43, 46])
        XCTAssertEqual(bass.map(\.start), [.zero, .quarter, .half, try .half.adding(.quarter)])
        XCTAssertEqual(bass.map(\.duration), Array(repeating: .quarter, count: 4))
        XCTAssertEqual(result.extent, .whole)
        XCTAssertEqual(result.renderNodes, [
            .source(sourceID: 0), .gain(input: 0, value: 0.9),
            .source(sourceID: 1), .gain(input: 2, value: 0.5),
            .mix(inputs: [1, 3])
        ])
        XCTAssertEqual(try Tempo(beatsPerMinute: 60).seconds(for: result.extent), 4)
        XCTAssertEqual(try Tempo(beatsPerMinute: 120).seconds(for: result.extent), 2)
    }
}
