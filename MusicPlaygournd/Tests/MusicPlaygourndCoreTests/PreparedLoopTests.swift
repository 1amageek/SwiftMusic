import Testing
@testable import MusicPlaygourndCore

struct PreparedLoopTests {
    @Test(.timeLimit(.minutes(3)))
    func testDecodedLoopValidationRejectsNonFiniteAndMismatchedSamples() throws {
        let invalidSamples = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: [Float.nan, 0],
            events: []
        )
        #expect {
            try invalidSamples.validate()
        } throws: { error in
            error as? PreparedLoopValidationError == .invalidSampleCount(2)
        }

        let invalidEvent = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 128,
                velocity: 80
            )]
        )
        #expect {
            try invalidEvent.validate()
        } throws: { error in
            if case .invalidEvent(index: 0, reason: "MIDI note is out of range") = error as? PreparedLoopValidationError { return true }
            return false
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testDecodedLoopValidationRejectsDuplicateRowsAndInvalidPeaks() throws {
        let duplicateRows = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [],
            rows: [
                LoopRow(sourceID: 0, label: "first", anchor: nil, peaks: [0]),
                LoopRow(sourceID: 0, label: "second", anchor: nil, peaks: [0])
            ]
        )
        #expect {
            try duplicateRows.validate()
        } throws: { error in
            if case .invalidRow(index: 1, reason: "duplicate source ID") = error as? PreparedLoopValidationError { return true }
            return false
        }

        let invalidPeaks = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [],
            rows: [
                LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [Float.nan])
            ]
        )
        #expect {
            try invalidPeaks.validate()
        } throws: { error in
            if case .invalidRow(index: 0, reason: "peak envelope contains an invalid value") = error as? PreparedLoopValidationError { return true }
            return false
        }

        let negativePatternIndex = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 60,
                velocity: 80,
                patternStepIndex: -1
            )],
            rows: [LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [0], patternText: "x ~")]
        )
        #expect {
            try negativePatternIndex.validate()
        } throws: { error in
            if case .invalidEvent(index: 0, reason: "negative pattern step index") = error as? PreparedLoopValidationError { return true }
            return false
        }

        let outOfRangePatternIndex = PreparedLoop(
            sampleRate: 44_100,
            bpm: 120,
            beatsPerBar: 4,
            beatCount: 4,
            samples: Array(repeating: 0, count: 176_400),
            events: [LoopEvent(
                sourceID: 0,
                label: "lead",
                startBeat: 0,
                durationBeats: 1,
                midiNote: 60,
                velocity: 80,
                patternStepIndex: 2
            )],
            rows: [LoopRow(sourceID: 0, label: "lead", anchor: nil, peaks: [0], patternText: "x ~")]
        )
        #expect {
            try outOfRangePatternIndex.validate()
        } throws: { error in
            if case .invalidEvent(index: 0, reason: "pattern step index is outside pattern text") = error as? PreparedLoopValidationError { return true }
            return false
        }
    }
}
