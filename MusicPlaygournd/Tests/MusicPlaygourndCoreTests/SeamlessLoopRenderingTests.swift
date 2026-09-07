import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct SeamlessLoopRenderingTests {
    private let renderer = LoopRenderer()

    private func beats(_ value: UInt64) throws -> MusicalTime {
        try MusicalTime(numerator: value, denominator: 1)
    }

    private func livePolicy(maximumBeats: MusicalTime = .whole) throws -> LiveLoopPolicy {
        try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: maximumBeats)
    }

    @Test(.timeLimit(.minutes(3)))
    func crossingEventMatchesCircularRotationWithoutRetrigger() throws {
        let crossingPattern: NotePattern = "C4"
        let crossingSound = Synthesizer(.sine).notes(crossingPattern.phase(.quarter))
        let referenceSound = Synthesizer(.sine).notes("C4")
        let policy = try livePolicy()
        let crossing = try renderer.render(
            SoundCompiler().compile(crossingSound, liveLoop: policy),
            bpm: 240,
            beatsPerBar: 4
        )
        let reference = try renderer.render(
            SoundCompiler().compile(referenceSound),
            bpm: 240,
            beatsPerBar: 4
        )

        #expect(crossing.events.count == 1)
        #expect(crossing.events[0].startBeat == 3)
        #expect(crossing.events[0].durationBeats == 4)
        #expect(crossing.events[0].wrapsLoopBoundary)
        #expect(crossing.events[0].isActive(at: 3.5, in: 4))
        #expect(crossing.events[0].isActive(at: 0.5, in: 4))
        #expect(crossing.events[0].isActive(at: 1, in: 4))

        let frameCount = crossing.samples.count / 2
        let startFrame = frameCount * 3 / 4
        let pcmMatches = (0..<frameCount * 2).allSatisfy { index in
            let frame = index / 2
            let channel = index % 2
            let referenceFrame = (frame - startFrame + frameCount) % frameCount
            let actual = crossing.samples[index]
            let expected = reference.samples[referenceFrame * 2 + channel]
            return abs(actual - expected) <= 0.000_001
        }
        #expect(pcmMatches)
        #expect(crossing.samples.contains { abs($0) > 0.01 })
    }

    @Test(.timeLimit(.minutes(3)))
    func finiteCompilationRetainsLegacyClippingAndMetadata() throws {
        let sound = Synthesizer(.sine).notes("C4")
        let compiled = try SoundCompiler().compile(sound)
        let loop = try renderer.render(compiled, bpm: 240, beatsPerBar: 4)

        #expect(compiled.playbackMode == .finite)
        #expect(loop.events.count == 1)
        #expect(loop.events[0].startBeat == 0)
        #expect(loop.events[0].durationBeats == 4)
        #expect(!loop.events[0].wrapsLoopBoundary)
        #expect(loop.samples.contains { abs($0) > 0.01 })

        let clipped = try renderer.render(
            SoundCompiler().compile(sound.gate(Double.greatestFiniteMagnitude)),
            bpm: 240,
            beatsPerBar: 4
        )
        #expect(clipped.events[0].durationBeats == 4)
        #expect(clipped.samples == loop.samples)

        let live = try SoundCompiler().compile(sound, liveLoop: try livePolicy())
        #expect(throws: LoopRenderingError.self) {
            try renderer.render(live, bpm: 240, beatsPerBar: 3)
        }
        #expect(throws: SoundCompilationError.liveEventDurationExceeded(index: 0)) {
            try SoundCompiler().compile(sound.gate(2), liveLoop: try livePolicy())
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func laterCycleGainAndPanMatchExplicitFiniteReferencePCM() throws {
        let patterned = Sample("kick")
            .rhythm("x")
            .gain("<1 0.5>")
            .pan("<-1 1>")
        let explicit = Sample("kick")
            .rhythm("x")
            .repeated(2)
            .gain("<1 0.5>")
            .pan("<-1 1>")

        let patternedLoop = try renderer.render(
            SoundCompiler().compile(
                patterned,
                liveLoop: try livePolicy(maximumBeats: try beats(8))
            ),
            bpm: 240,
            beatsPerBar: 4
        )
        let explicitLoop = try renderer.render(
            SoundCompiler().compile(explicit),
            bpm: 240,
            beatsPerBar: 4
        )

        #expect(patternedLoop.beatCount == 8)
        #expect(patternedLoop.events.map(\.startBeat) == [0, 4])
        #expect(patternedLoop.events.map(\.gain) == [1, 0.5])
        #expect(patternedLoop.events.map(\.pan) == [-1, 1])
        #expect(explicitLoop.events.map(\.startBeat) == [0, 4])
        #expect(explicitLoop.events.map(\.gain) == [1, 0.5])
        #expect(explicitLoop.events.map(\.pan) == [-1, 1])
        #expect(patternedLoop.samples.count == explicitLoop.samples.count)

        let pcmMatches = zip(patternedLoop.samples, explicitLoop.samples).allSatisfy { actual, expected in
            abs(actual - expected) <= 0.000_001
        }
        #expect(pcmMatches)
    }
}
