import SwiftMusic
import Testing

struct LiveWindowTests {
    private func beats(_ value: UInt64) throws -> MusicalTime {
        try MusicalTime(numerator: value, denominator: 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func independentNumericClocksResolveEveryOnsetBeforeTimeScaling() throws {
        let sound = Sample("kick")
            .rhythm("x", cycle: try beats(3))
            .gain("<1 0.5>")
            .pan("-1 1")
            .fast(2)
        let result = try SoundCompiler().compile(sound, liveLoop: LiveLoopPolicy(
            beatsPerBar: 4, maximumBeats: beats(32)))
        #expect(result.extent == (try beats(12)))
        #expect(result.events.map(\.gain) == [1, 1, 0.5, 1, 0.5, 0.5, 1, 0.5])
        #expect(result.events.map(\.pan) == [-1, 1, 1, -1, -1, 1, 1, -1])
        #expect(result.events.map(\.start) == (try (0..<8).map {
            try MusicalTime(numerator: UInt64($0 * 3), denominator: 2)
        }))
        #expect(result.sources.count == 1)
        #expect(result.renderNodes.count == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func crossingVoiceRetainsItsDurationAndLexicalIdentity() throws {
        let pattern: NotePattern = "C4"
        let sound = Synthesizer(.sine).notes(pattern.phase(.quarter))
        let result = try SoundCompiler().compile(sound, liveLoop: LiveLoopPolicy(
            beatsPerBar: 4, maximumBeats: beats(4)))
        #expect(result.extent == .whole)
        #expect(result.playbackMode == .seamlessLoop)
        #expect(result.events.count == 1)
        #expect(result.events[0].start == (try beats(3)))
        #expect(result.events[0].duration == .whole)
        #expect(result.events[0].patternStepIndex == 0)
        #expect(try SoundCompiler().compile(sound).extent == beats(7))
        #expect(throws: SoundCompilationError.liveEventDurationExceeded(index: 0)) {
            try SoundCompiler().compile(sound.gate(2), liveLoop: LiveLoopPolicy(
                beatsPerBar: 4, maximumBeats: beats(4)))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func expansionAndWindowFailuresAreExplicit() throws {
        let compiler = SoundCompiler(limits: try .init(maximumEvents: 10))
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: beats(32))
        #expect(throws: SoundCompilationError.maximumEventsExceeded(limit: 10)) {
            try compiler.compile(Sample("kick").rhythm("x", cycle: MusicalTime(
                numerator: 1, denominator: 1024)), liveLoop: policy)
        }
        #expect(throws: SoundCompilationError.liveWindowExceeded(maximum: try beats(32))) {
            try compiler.compile(Sample("kick").rhythm("~", cycle: beats(33)), liveLoop: policy)
        }
    }
}
