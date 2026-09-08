import SwiftMusic
import Testing

@MainActor
struct LiveDSLIntegrationTests {
    @Test(.timeLimit(.minutes(3)))
    func testPatternBoundariesAndCompilerLimitsRemainExplicitFailures() throws {
        let endpoints: NotePattern = "C-1 G9 B#3 Cb4 c#4 db4"
        #expect(try endpoints.steps.map { $0?.midiNote } == [0, 127, 60, 59, 61, 61])
        for text in ["", "C+4", "C#", "C4junk", "C♯4", "C999999999999999999999999999", "G#9"] {
            #expect(throws: (any Error).self) { try NotePattern(text) }
        }
        let dynamicRhythm: String = "x invalid"
        #expect(throws: (any Error).self) { try RhythmPattern(dynamicRhythm) }
        #expect(throws: (any Error).self) {
            try SoundCompiler().compile(Track("empty") {}.notes("invalid"))
        }
        #expect(throws: (any Error).self) {
            try SoundCompiler().compile(Track("empty") {}.rhythm("invalid"))
        }

        let rests = try SoundCompiler().compile(Synthesizer(.sine).notes("C2 ~ ~ ~", cycle: .half))
        #expect(rests.events.count == 1)
        #expect(rests.events.first?.duration == .eighth)
        #expect(rests.extent == .half)
        let allRests = try SoundCompiler().compile(Synthesizer(.sine).notes("~ ~"))
        #expect(allRests.events.isEmpty)
        #expect(allRests.extent == .whole)

        let compiler = SoundCompiler(limits: try .init(maximumEvents: 3))
        #expect {
            try compiler.compile(Synthesizer(.sine).notes("C2 D2 E2 F2"))
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 3)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testFailedEditPreservesAdoptedSoundAndRecoveryWaitsForBoundary() throws {
        var state = LiveMusicState()
        let began = state.beginUpdate(revision: 0)
        #expect(began)
        let received = state.receive(.prepare(revision: 0, sound: Sample("kick").rhythm("x ~ x ~")))
        #expect(received)
        #expect(state.currentSound == nil)
        let firstPending = state.adoptPendingAtBoundary()
        let first = try #require(firstPending)
        #expect(first.events.map(\.start) == [.zero, .half])

        let beganRevisionOne = state.beginUpdate(revision: 1)
        #expect(beganRevisionOne)
        let failedPreparation = state.receive(.prepare(revision: 1, sound: Sample("kick").rhythm("x ?")))
        #expect(failedPreparation)
        #expect(state.diagnostic != nil)
        #expect(state.diagnosticRevision == 1)
        #expect(state.pendingSound == nil)
        let pendingAfterFailure = state.adoptPendingAtBoundary()
        #expect(pendingAfterFailure == nil)
        #expect(state.currentSound == first)
        #expect(state.currentRevision == 0)

        let beganRevisionTwo = state.beginUpdate(revision: 2)
        #expect(beganRevisionTwo)
        let recoveredPreparation = state.receive(.prepare(revision: 2, sound: Sample("kick").rhythm("~ x ~ x")))
        #expect(recoveredPreparation)
        #expect(state.diagnostic == nil)
        #expect(state.currentSound == first)
        let nextPending = state.adoptPendingAtBoundary()
        let next = try #require(nextPending)
        #expect(next.events.map(\.start) == [.quarter, try .half.adding(.quarter)])
        #expect(state.currentRevision == 2)
        let pendingAfterAdoption = state.adoptPendingAtBoundary()
        #expect(pendingAfterAdoption == nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func testNewEditInvalidatesPendingAndRejectsOlderPreparationCompletions() throws {
        var state = LiveMusicState()
        let began = state.beginUpdate(revision: 0)
        #expect(began)
        let received = state.receive(.prepare(revision: 0, sound: Synthesizer(.sine).notes("C2")))
        #expect(received)
        let initialPending = state.adoptPendingAtBoundary()
        let initial = try #require(initialPending)

        let beganRevisionOne = state.beginUpdate(revision: 1)
        #expect(beganRevisionOne)
        let oldCompletion = LiveMusicUpdate.prepare(revision: 1, sound: Synthesizer(.sine).notes("D2"))
        let receivedOldCompletion = state.receive(oldCompletion)
        #expect(receivedOldCompletion)
        let beganRevisionTwo = state.beginUpdate(revision: 2)
        #expect(beganRevisionTwo)
        #expect(state.pendingSound == nil)
        let receivedStaleCompletion = state.receive(oldCompletion)
        #expect(!receivedStaleCompletion)
        let stalePending = state.adoptPendingAtBoundary()
        #expect(stalePending == nil)
        #expect(state.currentSound == initial)

        let failure = LiveMusicUpdate.prepare(revision: 2, sound: Synthesizer(.sine).notes("C2 nope"))
        let receivedFailure = state.receive(failure)
        #expect(receivedFailure)
        let receivedDuplicateFailure = state.receive(failure)
        #expect(!receivedDuplicateFailure)
        let beganOlderRevision = state.beginUpdate(revision: 1)
        #expect(!beganOlderRevision)
        #expect(state.diagnosticRevision == 2)
        #expect(state.currentSound == initial)

        let beganRevisionThree = state.beginUpdate(revision: 3)
        #expect(beganRevisionThree)
        let delayed = LiveMusicUpdate.prepare(revision: 3, sound: Sample("old"))
        let beganRevisionFour = state.beginUpdate(revision: 4)
        #expect(beganRevisionFour)
        let receivedDelayed = state.receive(delayed)
        #expect(!receivedDelayed)
        #expect(state.preparingRevision == 4)
        #expect(state.currentSound == initial)
    }

    @Test(.timeLimit(.minutes(3)))
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
        #expect(drums.map(\.start) == [.zero, .half])
        #expect(bass.map { $0.pitch?.midiNote } == [36, 39, 43, 46])
        #expect(bass.map(\.start) == [.zero, .quarter, .half, try .half.adding(.quarter)])
        #expect(bass.map(\.duration) == Array(repeating: .quarter, count: 4))
        #expect(result.extent == .whole)
        #expect(result.renderNodes == [
            .source(sourceID: 0), .gain(input: 0, value: 0.9),
            .source(sourceID: 1), .gain(input: 2, value: 0.5),
            .mix(inputs: [1, 3])
        ])
        #expect(try Tempo(beatsPerMinute: 60).seconds(for: result.extent) == 4)
        #expect(try Tempo(beatsPerMinute: 120).seconds(for: result.extent) == 2)
    }
}
