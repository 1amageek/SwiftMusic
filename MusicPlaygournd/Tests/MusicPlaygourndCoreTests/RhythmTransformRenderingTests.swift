import Testing
import SwiftMusic
@testable import MusicPlaygourndCore

struct RhythmTransformRenderingTests {
    @Test(.timeLimit(.minutes(3)))
    func swungEventsReachTheirExactNativeOnsetFrames() throws {
        let swing = try Swing(delay: MusicalTime(numerator: 1, denominator: 8))
        let sound = Synthesizer(.sine).rhythm("x*4", cycle: .half).gate(0.1).swing(swing)
        let compiled = try SoundCompiler().compile(sound,
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        let loop = try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        #expect(loop.events.map(\.startBeat) == [0, 0.625, 1, 1.625, 2, 2.625, 3, 3.625])
        #expect(loop.events.allSatisfy { $0.patternStepIndex == 0 })
        for event in loop.events {
            let frame = Int((event.startBeat * 0.5 * 44_100).rounded(.down))
            #expect(abs(loop.samples[(frame + 16) * 2]) > 0.000001)
            if frame >= 16 { #expect(loop.samples[(frame - 16) * 2] == 0) }
        }
        #expect(loop.beatCount == 4)
    }
}
