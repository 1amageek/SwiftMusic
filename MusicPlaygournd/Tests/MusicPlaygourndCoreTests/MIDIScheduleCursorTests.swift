import AVFoundation
import Testing
@testable import MusicPlaygourndCore

struct MIDIScheduleCursorTests {
    private func anchor(_ beat: Double, bpm: Double = 120, revision: UInt64 = 1) throws -> PlaybackClockAnchor {
        try PlaybackClockAnchor(presentationHostTime: AVAudioTime.hostTime(forSeconds: 100),
            accumulatedBeatPosition: beat, beatsPerMinute: bpm, loopBeatCount: 4,
            revision: revision, overrideGeneration: 0, isPlaying: true)
    }
    private func loop(_ events: [LoopEvent], beats: Double = 4) -> PreparedLoop {
        PreparedLoop(sampleRate: 44_100, bpm: 120, beatsPerBar: 4, beatCount: beats,
            samples: [], events: events)
    }
    private func event(start: Double, duration: Double, projection: MIDIEventProjection = .note(72)) -> LoopEvent {
        LoopEvent(sourceID: 0, label: "Note", startBeat: start, durationBeats: duration,
            midiNote: 60, velocity: 100, wrapsLoopBoundary: start + duration > 4,
            midiProjection: projection)
    }

    @Test func longNotesAndWrapEdgesAreScheduledIndependentlyWithoutDuplicates() throws {
        var cursor = MIDIScheduleCursor()
        let score = loop([event(start: 3.9, duration: 0.4)])
        let first = try cursor.notes(loop: score, from: 3.85, through: 4.05, channel: 2,
            anchor: anchor(3.85))
        #expect(first.map(\.message) == [.noteOn(channel: 2, note: 72, velocity: 100)])
        #expect(try cursor.notes(loop: score, from: 3.9, through: 4.1, channel: 2,
            anchor: anchor(3.9)).isEmpty)
        let off = try cursor.notes(loop: score, from: 4.2, through: 4.4, channel: 2,
            anchor: anchor(4.2))
        #expect(off.map(\.message) == [.noteOff(channel: 2, note: 72, velocity: 0)])
        let second = try cursor.notes(loop: score, from: 7.85, through: 8.05, channel: 2,
            anchor: anchor(7.85, revision: 2))
        #expect(second.map(\.message) == [.noteOn(channel: 2, note: 72, velocity: 100)])
        let secondOff = try cursor.notes(loop: score, from: 8.2, through: 8.4, channel: 2,
            anchor: anchor(8.2, revision: 2))
        #expect(secondOff.count == 1)
        let third = try cursor.notes(loop: score, from: 11.85, through: 12.05, channel: 2,
            anchor: anchor(11.85, revision: 3))
        #expect(third.count == 1)
    }

    @Test func edgeHostTimeUsesAbsoluteBeatAndPreservesHalfOpenBoundary() throws {
        var cursor = MIDIScheduleCursor()
        let score = loop([event(start: 0.1, duration: 0.1)])
        let clock = try anchor(0.15)
        let first = try cursor.notes(loop: score, from: 0.05, through: 0.2, channel: 1, anchor: clock)
        #expect(first.count == 1)
        #expect(first[0].hostTime == (try clock.hostTime(atBeat: 0.1)))
        let second = try cursor.notes(loop: score, from: 0.1, through: 0.3, channel: 1, anchor: clock)
        #expect(second.map(\.message) == [.noteOff(channel: 1, note: 72, velocity: 0)])
    }

    @Test func clockOrdinalsSurviveOverlapAndRateChange() throws {
        var cursor = MIDIScheduleCursor()
        let first = try cursor.clock(from: 0, through: 0.2, anchor: anchor(0))
        #expect(first.count == 5)
        let overlap = try cursor.clock(from: 0.1, through: 0.3, anchor: anchor(0.1))
        #expect(overlap.count == 3)
        let faster = try cursor.clock(from: 0.2, through: 0.6, anchor: anchor(0.2, bpm: 240))
        #expect(faster.count == 7)
        let all = first + overlap + faster
        #expect(all.allSatisfy { $0.message == .clock })
        let ordinals = try first.map { Int((try anchor(0).beat(atHostTime: $0.hostTime) * 24).rounded()) }
            + overlap.map { Int((try anchor(0.1).beat(atHostTime: $0.hostTime) * 24).rounded()) }
            + faster.map { Int((try anchor(0.2, bpm: 240).beat(atHostTime: $0.hostTime) * 24).rounded()) }
        #expect(ordinals == Array(0..<15))
    }

    @Test func acceptedNoteRetainsItsOffAcrossCodeAndPitchReplacement() throws {
        var cursor = MIDIScheduleCursor()
        let original = loop([event(start: 0, duration: 1)])
        let initial = try cursor.notes(loop: original, from: 0, through: 0.2, channel: 1, anchor: anchor(0))
        #expect(initial.map(\.message) == [.noteOn(channel: 1, note: 72, velocity: 100)])
        let replacement = loop([event(start: 2, duration: 1, projection: .note(84))])
        let off = try cursor.notes(loop: replacement, from: 1, through: 1.2, channel: 1,
            anchor: anchor(1, revision: 2))
        #expect(off.map(\.message) == [.noteOff(channel: 1, note: 72, velocity: 0)])
    }

    @Test func activeOccurrencesHaveAFixedBound() throws {
        var cursor = MIDIScheduleCursor()
        let score = loop((0..<2_049).map { event(start: Double($0) / 1_000, duration: 4) })
        for step in 0..<10 {
            let start = Double(step) / 5
            _ = try cursor.notes(loop: score, from: start, through: Double(step + 1) / 5,
                channel: 1, anchor: anchor(start))
        }
        #expect(throws: MIDIError.tooManyActiveNotes(limit: 2_048)) {
            try cursor.notes(loop: score, from: 2, through: 2.2, channel: 1, anchor: anchor(2))
        }
    }

    @Test func unsupportedAndOverBudgetBatchesDoNotAdvanceCursor() throws {
        var cursor = MIDIScheduleCursor()
        let invalid = loop([event(start: 0, duration: 1, projection: .unsupported(.fractionalPitch))])
        #expect(throws: MIDIError.unsupportedProjection(.fractionalPitch)) {
            try cursor.notes(loop: invalid, from: 0, through: 0.1, channel: 1, anchor: anchor(0))
        }
        let crowded = loop(Array(repeating: event(start: 0, duration: 1), count: 257))
        #expect(throws: MIDIError.tooManyMessages(limit: 256)) {
            try cursor.notes(loop: crowded, from: 0, through: 0.1, channel: 1, anchor: anchor(0))
        }
        let valid = loop([event(start: 0, duration: 1)])
        #expect(try cursor.notes(loop: valid, from: 0, through: 0.1, channel: 1, anchor: anchor(0)).count == 1)
        #expect(throws: MIDIError.timestampTooFar) {
            try cursor.clock(from: 0, through: 1, anchor: anchor(0))
        }
    }
}
