import SwiftMusic
import Testing

struct LiveRepeatWindowTests {
    private func beats(_ value: UInt64) throws -> MusicalTime {
        try MusicalTime(numerator: value, denominator: 1)
    }

    private func sixteenBeatPolicy() throws -> LiveLoopPolicy {
        try LiveLoopPolicy(beatsPerBar: 16, maximumBeats: try beats(16))
    }

    @Test(.timeLimit(.minutes(3)))
    func repeatedGainOrderingsResolveAcrossSixteenBeatWindow() throws {
        let innerGain = Sample("kick")
            .rhythm("x")
            .gain("<1 0.5>")
            .repeated(2)
        let outerGain = Sample("kick")
            .rhythm("x")
            .repeated(2)
            .gain("<1 0.5>")
        let compiler = SoundCompiler()
        let policy = try sixteenBeatPolicy()
        let starts = try [0, 4, 8, 12].map { try beats(UInt64($0)) }

        let inner = try compiler.compile(innerGain, liveLoop: policy)
        #expect(inner.extent == (try beats(16)))
        #expect(inner.events.map(\.start) == starts)
        #expect(inner.events.map(\.gain) == [1, 1, 1, 1])

        let outer = try compiler.compile(outerGain, liveLoop: policy)
        #expect(outer.extent == (try beats(16)))
        #expect(outer.events.map(\.start) == starts)
        #expect(outer.events.map(\.gain) == [1, 0.5, 1, 0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func repeatedAlternatingNotesKeepFiniteTemplateAndGraphIdentity() throws {
        let sound = Synthesizer(.sine)
            .notes("<C4 D4>")
            .repeated(2)
        let compiler = SoundCompiler()
        let policy = try sixteenBeatPolicy()
        let starts = try [0, 4, 8, 12].map { try beats(UInt64($0)) }

        let finite = try compiler.compile(sound)
        #expect(finite.extent == (try beats(16)))
        #expect(finite.events.map(\.start) == starts)
        #expect(finite.events.compactMap(\.pitch).map(\.midiNote) == [60, 62, 60, 62])

        let live = try compiler.compile(sound, liveLoop: policy)
        #expect(live.extent == (try beats(16)))
        #expect(live.events.map(\.start) == starts)
        #expect(live.events.compactMap(\.pitch).map(\.midiNote) == [60, 62, 60, 62])
        #expect(live.sources.count == 1)
        #expect(live.renderNodes.count == 1)
    }
}
