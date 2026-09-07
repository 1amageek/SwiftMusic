import Testing
import SwiftMusic

struct RhythmEventTransformTests {
    private let compiler = SoundCompiler()

    @Test(.timeLimit(.minutes(3)))
    func swingUsesExactCellsAndCommonLiveWindow() throws {
        let swing = try Swing(delay: MusicalTime(numerator: 1, denominator: 8))
        let base = Synthesizer(.sine).rhythm("x*4", cycle: .half)
        let finite = try compiler.compile(base.swing(swing))
        #expect(finite.events.map(\.start) == [.zero, try MusicalTime(numerator: 5, denominator: 8),
            .quarter, try MusicalTime(numerator: 13, denominator: 8)])
        #expect(finite.extent == (try MusicalTime(numerator: 17, denominator: 8)))
        let live = try compiler.compile(base.swing(swing), liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(live.extent == .whole)
        #expect(live.events.count == 8)
        #expect(live.events[5].start == (try MusicalTime(numerator: 21, denominator: 8)))
        #expect(live.events.map(\.patternStepIndex) == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(try compiler.compile(base.swing(Swing(delay: .zero))).events == compiler.compile(base).events)
        #expect(throws: RhythmTransformError.invalidSwing) { try Swing(delay: .eighth) }
    }

    @Test(.timeLimit(.minutes(3)))
    func euclideanDistributionRotationAndZeroPulsesAreExact() throws {
        let base = Synthesizer(.sine)
        let plain = try compiler.compile(base.euclidean(EuclideanRhythm(pulses: 3, steps: 8)))
        #expect(plain.events.map(\.start) == [.zero, try MusicalTime(numerator: 3, denominator: 2), .beats(3)])
        #expect(plain.events.allSatisfy { $0.duration == .eighth && $0.sourceID == 0 })
        let rotated = try compiler.compile(base.euclidean(EuclideanRhythm(pulses: 3, steps: 8, rotation: 1)))
        #expect(rotated.events.map(\.start) == [.eighth, .half, try MusicalTime(numerator: 7, denominator: 2)])
        let empty = try compiler.compile(base.euclidean(EuclideanRhythm(pulses: 0, steps: 8)))
        #expect(empty.events.isEmpty && empty.extent == .whole)
        let five = try compiler.compile(base.euclidean(EuclideanRhythm(pulses: 5, steps: 8)))
        #expect(five.events.map(\.start) == [.zero, .quarter, try MusicalTime(numerator: 3, denominator: 2),
                                            try MusicalTime(numerator: 5, denominator: 2), .beats(3)])
        #expect(throws: RhythmTransformError.invalidEuclidean) { try EuclideanRhythm(pulses: 9, steps: 8) }
    }

    @Test(.timeLimit(.minutes(3)))
    func ratchetPreservesPitchTokenTrackAndDuckIdentity() throws {
        struct Song: Music {
            let depth: Decibels
            var body: some Sound {
                Track("lead") {
                    Synthesizer(.sine).notes("C4 D4")
                        .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(10))
                        .ratchet(3)
                }.send(to: "room", level: 1)
                BusReturn("room")
            }
        }
        let result = try compiler.compile(Song(depth: Decibels(value: -6)))
        #expect(result.events.count == 6)
        let starts = try (0..<6).map { try MusicalTime(numerator: UInt64($0 * 2), denominator: 3) }
        let duration = try MusicalTime(numerator: 2, denominator: 3)
        #expect(result.events.map(\.start) == starts)
        #expect(result.events.allSatisfy { $0.duration == duration && $0.trackID == 0 })
        #expect(result.events.map(\.patternStepIndex) == [0, 0, 0, 1, 1, 1])
        #expect(result.eventDucks.map(\.triggerEventIndex) == Array(0..<6))
        #expect(result.extent == .whole)
        #expect(throws: SoundCompilationError.invalidRhythmTransform(.invalidRatchet)) {
            try compiler.compile(Synthesizer(.sine).ratchet(0))
        }
        let limited = SoundCompiler(limits: try .init(maximumEvents: 2))
        #expect(throws: SoundCompilationError.maximumEventsExceeded(limit: 2)) {
            try limited.compile(Synthesizer(.sine).rhythm("x x").ratchet(2))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func probabilityUsesFrozenSeedAndRepeatsCanonicalChoices() throws {
        let base = Synthesizer(.sine).rhythm("x*8")
        let value = try Probability(chance: 0.5, seed: 42)
        let first = try compiler.compile(base.probability(value))
        #expect(first.events.map(\.start) == [try MusicalTime(numerator: 1, denominator: 2), .quarter,
            try MusicalTime(numerator: 3, denominator: 2), .half, .beats(3)])
        #expect(first == (try compiler.compile(base.probability(value))))
        #expect(try compiler.compile(base.probability(Probability(chance: 0, seed: 42))).events.isEmpty)
        #expect(try compiler.compile(base.probability(Probability(chance: 1, seed: 42))).events == compiler.compile(base).events)
        let live = try compiler.compile(base.probability(value), liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(live.events == first.events)
        let seed = Synthesizer(.sine)
        #expect(try compiler.compile(seed.probability(value).ratchet(4)).events.isEmpty)
        #expect(try compiler.compile(seed.ratchet(4).probability(value)).events.count == 3)
        #expect(throws: RhythmTransformError.invalidProbability) { try Probability(chance: .nan, seed: 1) }
    }

    @Test(.timeLimit(.minutes(3)))
    func humanizationHasSignedTimingSaturationAndLiveWrap() throws {
        let base = Synthesizer(.sine).rhythm("x x x x")
        let positive = try Humanization(timingStep: .sixteenth, timingOffsets: 1...1, velocityOffsets: 100...100, seed: 7)
        let finite = try compiler.compile(base.humanize(positive))
        #expect(finite.events.first?.start == .sixteenth)
        #expect(finite.events.allSatisfy { $0.velocity == 127 })
        let negative = try Humanization(timingStep: .sixteenth, timingOffsets: -1 ... -1, velocityOffsets: -100 ... -100, seed: 7)
        #expect(throws: SoundCompilationError.invalidRhythmTransform(.negativeEventTime)) {
            try compiler.compile(base.humanize(negative))
        }
        let live = try compiler.compile(base.humanize(negative), liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(live.events.map(\.start) == [try MusicalTime(numerator: 3, denominator: 4),
            try MusicalTime(numerator: 7, denominator: 4), try MusicalTime(numerator: 11, denominator: 4),
            try MusicalTime(numerator: 15, denominator: 4)])
        #expect(live.events.allSatisfy { $0.velocity == 1 })
        #expect(live.events.map(\.patternStepIndex) == [1, 2, 3, 0])
        #expect(throws: RhythmTransformError.invalidHumanization) {
            try Humanization(timingStep: .zero, timingOffsets: -1...1, velocityOffsets: 0...0, seed: 0)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func transformsPreserveSourceTrackTokenAndResolvedDuckProvenance() throws {
        struct Song: Music {
            let content: ModifiedSound
            var body: some Sound {
                Track("lead") { content }.send(to: "room", level: 1)
                BusReturn("room")
            }
        }
        let base = Synthesizer(.sine).notes("C4 D4 E4 F4")
            .duck(targetBus: "room", depth: try Decibels(value: -6),
                  attack: .zero, recovery: .milliseconds(10))
        let baseline = try compiler.compile(Song(content: base))
        let variants = [
            base.swing(try Swing(subdivision: .quarter, delay: .sixteenth)),
            base.euclidean(try EuclideanRhythm(pulses: 3, steps: 8)),
            base.probability(try Probability(chance: 0.5, seed: 42)),
            base.humanize(try Humanization(timingStep: .sixteenth, timingOffsets: 1...1,
                                          velocityOffsets: 0...0, seed: 7)),
            base.periodically(try PeriodicRhythmTransform(every: 2, cycle: .half,
                                                          transform: .reversed))
        ]
        let pitches: [UInt8] = [60, 62, 64, 65]
        for variant in variants {
            let result = try compiler.compile(Song(content: variant))
            #expect(!result.events.isEmpty)
            #expect(result.sources == baseline.sources)
            for event in result.events {
                #expect(event.sourceID == 0 && event.trackID == 0)
                let token = try #require(event.patternStepIndex)
                try #require(pitches.indices.contains(token))
                #expect(event.pitch?.midiNote == pitches[token])
            }
            #expect(result.eventDucks.map(\.triggerEventIndex) == Array(result.events.indices))
            #expect(result.eventDucks.allSatisfy {
                $0.targetBus == "room" && $0.depthDecibels == -6
                    && $0.attackSeconds == 0 && $0.recoverySeconds == 0.01
            })
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func periodicTransformsRespectCyclePhaseAndCrossingFailure() throws {
        let base = Synthesizer(.sine).rhythm("x x x x x x x x")
        let reverse = try PeriodicRhythmTransform(every: 2, cycle: .half, transform: .reversed)
        let result = try compiler.compile(base.periodically(reverse))
        #expect(result.events.map(\.patternStepIndex) == [3, 2, 1, 0, 4, 5, 6, 7])
        let rotated = try compiler.compile(base.periodically(PeriodicRhythmTransform(every: 2, cycle: .half,
                                                                                     transform: .rotated(by: .eighth))))
        #expect(rotated.events.map(\.patternStepIndex) == [3, 0, 1, 2, 4, 5, 6, 7])
        let ratcheted = try compiler.compile(base.periodically(PeriodicRhythmTransform(every: 2, phase: 1,
            cycle: .half, transform: .ratcheted(2))))
        #expect(ratcheted.events.count == 12)
        #expect(ratcheted.events.prefix(4).map(\.patternStepIndex) == [0, 1, 2, 3])
        let live = try compiler.compile(base.periodically(reverse), liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(live.events == result.events)
        let crossingOutput = try compiler.compile(Synthesizer(.sine)
            .notes("C4", cycle: .quarter).offset(.eighth)
            .periodically(PeriodicRhythmTransform(every: 1, cycle: .half,
                                                   transform: .rotated(by: .quarter))))
        #expect(crossingOutput.events.first?.start == (try MusicalTime(numerator: 3, denominator: 2)))
        #expect(crossingOutput.events.first?.duration == .quarter)
        #expect(crossingOutput.extent == (try MusicalTime(numerator: 5, denominator: 2)))
        #expect(throws: SoundCompilationError.invalidRhythmTransform(.crossingCycle)) {
            try compiler.compile(Synthesizer(.sine).notes("C4").periodically(reverse))
        }
    }
}
