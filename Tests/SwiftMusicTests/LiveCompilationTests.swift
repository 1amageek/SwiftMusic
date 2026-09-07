import Synchronization
import SwiftMusic
import Testing

struct LiveCompilationTests {
    private func time(_ numerator: UInt64, _ denominator: UInt64 = 1) throws -> MusicalTime {
        try MusicalTime(numerator: numerator, denominator: denominator)
    }

    private func policy(maximumBeats: MusicalTime = .whole) throws -> LiveLoopPolicy {
        try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: maximumBeats)
    }

    @Test(.timeLimit(.minutes(3)))
    func independentThreeAndFourBeatProgramsUseTwelveBeatWindow() throws {
        struct IndependentCycles: Sound {
            let threeBeats: MusicalTime
            let fourBeats: MusicalTime

            var body: some Sound {
                Sample("three").rhythm("x", cycle: threeBeats)
                Sample("four").rhythm("x", cycle: fourBeats)
            }
        }

        let sound = IndependentCycles(
            threeBeats: try time(3),
            fourBeats: try time(4)
        )
        let compiled = try SoundCompiler().compile(
            sound,
            liveLoop: try policy(maximumBeats: try time(12))
        )

        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == (try time(12)))
        #expect(compiled.events.map(\.start) == [
            .zero, .zero, try time(3), try time(4),
            try time(6), try time(8), try time(9)
        ])
    }

    @Test(.timeLimit(.minutes(3)))
    func nestedRhythmCartesianExpansionPreservesInnerOccurrences() throws {
        let sound = Sample("kick")
            .rhythm("x", cycle: try time(3))
            .rhythm("x x", cycle: try time(4))
        let compiled = try SoundCompiler().compile(
            sound,
            liveLoop: try policy(maximumBeats: try time(12))
        )

        #expect(compiled.extent == (try time(12)))
        #expect(compiled.events.map(\.start) == [
            .zero, try time(2), try time(3), try time(5),
            try time(6), try time(8), try time(9), try time(11)
        ])
    }

    @Test(.timeLimit(.minutes(3)))
    func postGeneratorGainExtendsPeriodButPreGeneratorGainDoesNot() throws {
        let post = try SoundCompiler().compile(
            Sample("post").rhythm("x").gain("<1 0.5>"),
            liveLoop: try policy(maximumBeats: try time(8))
        )
        let pre = try SoundCompiler().compile(
            Sample("pre").gain("<1 0.5>").rhythm("x"),
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(post.extent == (try time(8)))
        #expect(post.events.map(\.start) == [.zero, .whole])
        #expect(post.events.map(\.gain) == [1, 0.5])
        #expect(pre.extent == .whole)
        #expect(pre.events.map(\.gain) == [1])
    }

    @Test(.timeLimit(.minutes(3)))
    func repeatedSoundSnapshotsInnerValuesBeforeOuterSampling() throws {
        let inner = try SoundCompiler().compile(
            Sample("inner")
                .rhythm("x")
                .gain("<1 0.5>")
                .repeated(2),
            liveLoop: try policy(maximumBeats: try time(8))
        )
        let outer = try SoundCompiler().compile(
            Sample("outer")
                .rhythm("x")
                .repeated(2)
                .gain("<1 0.5>"),
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(inner.extent == (try time(8)))
        #expect(inner.events.map(\.start) == [.zero, .whole])
        #expect(inner.events.map(\.gain) == [1, 1])
        #expect(outer.extent == (try time(8)))
        #expect(outer.events.map(\.start) == [.zero, .whole])
        #expect(outer.events.map(\.gain) == [1, 0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func nestedGainProgramResamplesEveryInnerCycle() throws {
        let sound = Sample("kick")
            .rhythm("x")
            .gain("<1 0.5>")
            .rhythm("x")
        let compiled = try SoundCompiler().compile(
            sound,
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(compiled.extent == (try time(8)))
        #expect(compiled.events.map(\.start) == [.zero, .whole])
        #expect(compiled.events.map(\.gain) == [1, 0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func arrayNotesDoNotCreateAnIndependentRecurrencePeriod() throws {
        let c4 = try Pitch(midiNote: 60)
        let e4 = try Pitch(midiNote: 64)
        let sound = Synthesizer(.sine)
            .repeated(2)
            .notes([c4, e4])
            .rhythm("x")
        let compiled = try SoundCompiler().compile(
            sound,
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(compiled.extent == .whole)
        #expect(compiled.events.map(\.pitch) == [c4, e4])
        #expect(compiled.events.map(\.start) == [.zero, .quarter])
    }

    @Test(.timeLimit(.minutes(3)))
    func oneShotKeepsFiniteEventsInsideTheLiveWindow() throws {
        let compiled = try SoundCompiler().compile(
            Sample("fill").rhythm("x").oneShot(),
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == .whole)
        #expect(compiled.events.count == 1)
        #expect(compiled.events[0].start == .zero)
    }

    @available(macOS 15.0, *)
    @Test(.timeLimit(.minutes(3)))
    func customSoundBodyIsEvaluatedOnceDuringLiveCompilation() throws {
        final class BodyCounter: Sendable {
            let storage = Mutex(0)

            func increment() {
                storage.withLock { $0 += 1 }
            }

            var value: Int {
                storage.withLock { $0 }
            }
        }

        struct CountingSound: Sound {
            let counter: BodyCounter

            var body: some Sound {
                counter.increment()
                return Sample("kick").rhythm("x")
            }
        }

        let counter = BodyCounter()
        _ = try SoundCompiler().compile(
            CountingSound(counter: counter),
            liveLoop: try policy(maximumBeats: try time(8))
        )

        #expect(counter.value == 1)
    }

    @Test(.timeLimit(.minutes(3)))
    func recurringAndFiniteOffsetsRemainDistinct() throws {
        struct OffsetGroup: Sound {
            var body: some Sound {
                Sample("recurring").rhythm("x").offset(.quarter)
                Sample("finite").offset(.whole)
            }
        }

        let compiled = try SoundCompiler().compile(
            OffsetGroup(),
            liveLoop: try policy(maximumBeats: try time(12))
        )

        #expect(compiled.extent == (try time(8)))
        #expect(compiled.events.filter { $0.sourceID == 0 }.count == 2)
        #expect(compiled.events.filter { $0.sourceID == 1 }.count == 1)
        #expect(compiled.events.filter { $0.sourceID == 1 }.first?.start == .whole)

        let delayed = Sample("delayed").offset(.whole).rhythm("x")
        let finite = try SoundCompiler().compile(delayed)
        let recurring = try SoundCompiler().compile(delayed, liveLoop: policy())
        #expect(finite.events.map(\.start) == [.whole])
        #expect(recurring.events.map(\.start) == [.zero])
    }

    @Test(.timeLimit(.minutes(3)))
    func allRestRecurrenceRetainsItsWindowWithoutInventingEvents() throws {
        let compiled = try SoundCompiler().compile(
            Sample("rest").rhythm("~ ~"),
            liveLoop: try policy()
        )

        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == .whole)
        #expect(compiled.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(3)))
    func livePoliciesAndCompilerLimitsFailBeforeUnboundedEmission() throws {
        #expect {
            try LiveLoopPolicy(beatsPerBar: 0, maximumBeats: .whole)
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter("Beats per bar must be positive")
        }
        #expect {
            try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .zero)
        } throws: { error in
            error as? SoundCompilationError == .invalidParameter("Maximum live beats must be positive")
        }

        let windowLimited = try policy()
        #expect {
            try SoundCompiler().compile(
                Sample("kick").rhythm("x").gain("<1 0.5>"),
                liveLoop: windowLimited
            )
        } throws: { error in
            error as? SoundCompilationError == .liveWindowExceeded(maximum: .whole)
        }

        let eventLimitedCompiler = SoundCompiler(limits: try .init(maximumEvents: 2))
        #expect {
            try eventLimitedCompiler.compile(
                Sample("kick").rhythm("x"),
                liveLoop: try LiveLoopPolicy(beatsPerBar: 12, maximumBeats: try time(12))
            )
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 2)
        }

        #expect {
            try SoundCompiler().compile(
                Sample("kick").rhythm("x").gate(2),
                liveLoop: try policy()
            )
        } throws: { error in
            error as? SoundCompilationError == .liveEventDurationExceeded(index: 0)
        }
    }
}
