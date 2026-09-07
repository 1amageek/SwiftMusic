import Foundation
import MusicPlaygourndCore
import Testing

struct LoopBoundaryTests {
    @Test(.timeLimit(.minutes(3)))
    func continuationKeepsOneEventAndUsesHalfOpenCircularRanges() throws {
        let event = LoopEvent(sourceID: 0, label: "tone", startBeat: 3, durationBeats: 2,
            midiNote: 60, velocity: 80, patternStepIndex: 7, wrapsLoopBoundary: true)
        var ranges: [Range<Double>] = []
        event.forEachBeatRange(in: 4) { ranges.append($0) }
        #expect(ranges == [3..<4, 0..<1])
        #expect([0.0, 0.5, 3, 3.9].allSatisfy { event.isActive(at: $0, in: 4) })
        #expect([1.0, 2, 4, -1, .nan].allSatisfy { !event.isActive(at: $0, in: 4) })
        #expect(event.patternStepIndex == 7)
        let decoded = try JSONDecoder().decode(LoopEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)

        let legacy = Data(#"{"sourceID":0,"label":"tone","startBeat":3,"durationBeats":1,"gain":1,"velocity":80}"#.utf8)
        #expect(try JSONDecoder().decode(LoopEvent.self, from: legacy).wrapsLoopBoundary == false)
    }

    @Test(.timeLimit(.minutes(3)))
    func onlyExplicitSingleWindowContinuationsPassValidation() throws {
        func loop(start: Double = 3, duration: Double, wraps: Bool) -> PreparedLoop {
            PreparedLoop(sampleRate: 44_100, bpm: 240, beatsPerBar: 4, beatCount: 4,
                samples: [Float](repeating: 0, count: 88_200),
                events: [LoopEvent(sourceID: 0, label: "tone", startBeat: start,
                    durationBeats: duration, midiNote: 60, velocity: 80, wrapsLoopBoundary: wraps)])
        }
        try loop(duration: 4, wraps: true).validate()
        try loop(duration: 1, wraps: false).validate()
        for invalid in [loop(duration: 2, wraps: false), loop(duration: 5, wraps: true),
                        loop(duration: 1, wraps: true), loop(start: 4, duration: 1, wraps: true)] {
            #expect(throws: PreparedLoopValidationError.self) { try invalid.validate() }
        }
    }
}
