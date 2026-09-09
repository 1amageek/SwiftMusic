import Foundation
import Observation
import Testing
import SwiftMusic

@MainActor
struct SoundCompositionTests {
    @Test(.timeLimit(.minutes(1)))
    func localStateRetainsIdentityAndChangesCompiledBranch() async throws {
        enum Section: Sendable { case intro, groove }
        struct Session: Music {
            @SwiftMusic.State private var section = Section.intro
            @MainActor var selection: SwiftMusic.State<Section> { $section }
            var body: some Sound {
                switch section {
                case .intro: Sample("intro")
                case .groove: Sample("groove")
                }
            }
        }
        let session = Session()
        let copy = session
        let other = Session()
        let compiler = SoundCompiler()
        #expect(try compiler.compile(session).sources.map(\.kind) == [.sample("intro")])
        #expect(session.selection === copy.selection)
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        withObservationTracking {
            _ = session.selection.wrappedValue
        } onChange: {
            continuation.yield(())
        }
        copy.selection.wrappedValue = .groove
        var notifications = changes.makeAsyncIterator()
        #expect(await notifications.next() != nil)
        #expect(try compiler.compile(session).sources.map(\.kind) == [.sample("groove")])
        #expect(other.selection.wrappedValue == .intro)
    }

    private func pitch(_ value: UInt8) throws -> Pitch {
        try Pitch(midiNote: value)
    }

    @Test(.timeLimit(.minutes(3)))
    func testMusicSoundBuilderSourcesAndParallelDefaults() throws {
        struct Fragment: Sound {
            var body: some Sound {
                Sample("kick")
                Synthesizer(.sine)
            }
        }

        struct Song: Music {
            var body: some Sound {
                Fragment()
                Track("empty") {}
            }
        }

        let compiled = try SoundCompiler().compile(Song())

        #expect(compiled.events.count == 2)
        #expect(compiled.events.map(\.start) == [.zero, .zero])
        #expect(compiled.events.map(\.duration) == [.quarter, .quarter])
        #expect(compiled.events[0].pitch == nil)
        #expect(compiled.events[1].pitch == .middleC)
        #expect(compiled.sources.map(\.id) == [0, 1])
        #expect(compiled.sources.map(\.kind) == [.sample("kick"), .synthesizer(.sine)])
        #expect(compiled.tracks.map(\.name) == ["empty"])
    }

    @Test(.timeLimit(.minutes(3)))
    func testSoundBuilderBranchesAvailabilityOptionalAndFiniteLoops() throws {
        struct Branches: Sound {
            let includeFirst: Bool

            var body: some Sound {
                if includeFirst {
                    Sample("first")
                } else {
                    Sample("alternate")
                }

                if includeFirst {
                    Sample("optional")
                }

                if #available(macOS 14, *) {
                    Sample("available")
                } else {
                    Sample("fallback")
                }

                for name in ["loop-a", "loop-b"] {
                    Sample(name)
                }
            }
        }

        let included = try SoundCompiler().compile(Branches(includeFirst: true))
        #expect(included.sources.map(\.kind) == [
            .sample("first"), .sample("optional"), .sample("available"),
            .sample("loop-a"), .sample("loop-b")
        ])

        let excluded = try SoundCompiler().compile(Branches(includeFirst: false))
        #expect(excluded.sources.map(\.kind) == [
            .sample("alternate"), .sample("available"),
            .sample("loop-a"), .sample("loop-b")
        ])
    }

    @Test(.timeLimit(.minutes(3)))
    func testRhythmOffsetRepeatFastSlowAndTrailingExtent() throws {
        let pattern = try RhythmPattern(validating: "x ~ x")
        let rhythmic = Sample("hat").rhythm(pattern, cycle: .whole)
        let compiled = try SoundCompiler().compile(rhythmic)

        #expect(compiled.events.count == 2)
        #expect(compiled.events.map(\.start) == [
            .zero,
            try MusicalTime(numerator: 8, denominator: 3)
        ])
        #expect(compiled.events.map(\.duration) == [
            try MusicalTime(numerator: 4, denominator: 3),
            try MusicalTime(numerator: 4, denominator: 3)
        ])
        #expect(compiled.extent == .whole)

        let repeated = try SoundCompiler().compile(
            Sample("hat").repeated(3)
        )
        #expect(repeated.events.map(\.start) == [.zero, .quarter, .half])
        let repeatedExtent = try MusicalTime.quarter.multiplied(by: 3)
        #expect(repeated.extent == repeatedExtent)

        let fast = try SoundCompiler().compile(Sample("hat").fast(2))
        #expect(fast.events[0].duration == .eighth)
        #expect(fast.extent == .eighth)

        let slow = try SoundCompiler().compile(Sample("hat").slow(2))
        #expect(slow.events[0].duration == .half)
        #expect(slow.extent == .half)

        let shifted = try SoundCompiler().compile(
            Sample("hat").offset(.half)
        )
        #expect(shifted.events[0].start == .half)
        let shiftedExtent = try MusicalTime.half.adding(.quarter)
        #expect(shifted.extent == shiftedExtent)
    }

    @Test(.timeLimit(.minutes(3)))
    func testPitchHarmonyAndEventOrder() throws {
        let sound = Synthesizer(.sine)
            .notes([try pitch(60)])
            .chord(.major)
            .transpose(1)
        let compiled = try SoundCompiler().compile(sound)

        #expect(compiled.events.map { $0.pitch?.midiNote } == [61, 65, 68])

        let cycling = try SoundCompiler().compile(
            Synthesizer(.square).repeated(3).notes([try pitch(60), try pitch(64)])
        )
        #expect(cycling.events.map { $0.pitch?.midiNote } == [60, 64, 60])

        #expect {
            try SoundCompiler().compile(Sample("noise").transpose(1))
        } throws: { error in
            error as? SoundCompilationError == .missingPitch
        }

        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).notes([try pitch(127)]).transpose(1))
        } throws: { error in
            error as? SoundCompilationError == .pitchOutOfRange
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testFixedChordPresetsExpandExpectedIntervals() throws {
        let expected: [(Chord, [UInt8])] = [
            (.minor, [60, 63, 67]),
            (.power, [60, 67]),
            (.dominantSeventh, [60, 64, 67, 70])
        ]

        for (chord, notes) in expected {
            let compiled = try SoundCompiler().compile(
                Synthesizer(.sine)
                    .notes([try pitch(60)])
                    .chord(chord)
            )
            #expect(compiled.events.compactMap(\.pitch?.midiNote) == notes)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testExpressionModifiersPreserveTime() throws {
        let sound = Synthesizer(.sine)
            .dynamic(.ff)
            .velocity(100)
            .gate(0.5)
            .staccato()
        let compiled = try SoundCompiler().compile(sound)

        #expect(compiled.events[0].velocity == 100)
        #expect(abs((compiled.events[0].gate) - (0.25)) < 0.000_001)
        #expect(compiled.events[0].duration == .quarter)
        #expect(compiled.extent == .quarter)
    }

    @Test(.timeLimit(.minutes(3)))
    func testSourceSettingsAndCapabilityBoundaries() throws {
        let tuning = try Tuning(referencePitch: .middleC, frequencyHz: 442)
        let envelope = try Envelope(
            attackSeconds: 0.01,
            decaySeconds: 0.1,
            sustainLevel: 0.7,
            releaseSeconds: 0.2
        )
        let region = try SampleRegion(startFraction: 0.1, endFraction: 0.9)
        let unison = try Unison(voices: 3, detuneCents: 12)
        let fileSample = try Sample(file: URL(fileURLWithPath: "/tmp/piano.caf"))

        let sample = try SoundCompiler().compile(
            fileSample
                .tuning(tuning)
                .envelope(envelope)
                .sampleRegion(region)
        )
        #expect(sample.sources[0].tuning == tuning)
        #expect(sample.sources[0].envelope == envelope)
        #expect(sample.sources[0].sampleRegion == region)
        #expect(sample.sources[0].unison == nil)

        let synth = try SoundCompiler().compile(
            Synthesizer(.saw)
                .tuning(tuning)
                .envelope(envelope)
                .unison(unison)
        )
        #expect(synth.sources[0].tuning == tuning)
        #expect(synth.sources[0].envelope == envelope)
        #expect(synth.sources[0].unison == unison)

        #expect {
            try SoundCompiler().compile(Sample("piano").unison(unison))
        } throws: { error in
            guard case .unsupportedSourceSetting = error as? SoundCompilationError else {
                Issue.record("Expected unsupported source setting, received \(error)")
                return false
            }
            return true
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testEffectsMixAndRoutingRenderPlanOrder() throws {
        let delay = AudioEffect.delay(time: .quarter, feedback: 0.2, wet: 0.4)
        let reverb = AudioEffect.reverb(roomSize: 0.5, wet: 0.3)
        let chain = Synthesizer(.sine)
            .effect(delay)
            .effect(reverb)
        let compiled = try SoundCompiler().compile(chain)

        #expect(compiled.renderNodes.count == 3)
        #expect(compiled.rootNodeIDs == [2])
        guard case .source(sourceID: 0) = compiled.renderNodes[0] else {
            Issue.record("expected source node")
            return
        }
        guard case .effect(input: 0, effect: delay) = compiled.renderNodes[1] else {
            Issue.record("expected first effect node")
            return
        }
        guard case .effect(input: 1, effect: reverb) = compiled.renderNodes[2] else {
            Issue.record("expected second effect node")
            return
        }

        struct Pair: Sound {
            var body: some Sound {
                Synthesizer(.sine)
                Synthesizer(.square)
            }
        }
        let mixed = try SoundCompiler().compile(
            Pair().effect(.distortion(drive: 0.5))
        )
        #expect(mixed.rootNodeIDs == [3])
        #expect(mixed.renderNodes[2] == CompiledRenderNode.mix(inputs: [0, 1]))
        #expect(mixed.renderNodes[3] == CompiledRenderNode.effect(input: 2, effect: .distortion(drive: 0.5)))

        let routed = try SoundCompiler().compile(
            Synthesizer(.triangle)
                .gain(0.5)
                .pan(-0.25)
                .muted()
                .send(to: "reverb", level: 0.2)
                .output("main")
        )
        #expect(routed.renderNodes.count == 6)
        #expect(routed.rootNodeIDs == [5])
    }

    @Test(.timeLimit(.minutes(3)))
    func testEveryEffectAcceptsValidValuesAndRejectsInvalidValues() throws {
        let valid: [AudioEffect] = [
            .equalizer(frequencyHz: 440, gainDecibels: -3, q: 0.7),
            .filter(kind: .highPass, cutoffHz: 800, resonance: 0.2),
            .compressor(thresholdDecibels: -12, ratio: 4),
            .distortion(drive: 0.5),
            .delay(time: .eighth, feedback: 0.3, wet: 0.5),
            .reverb(roomSize: 0.6, wet: 0.4),
            .chorus(rateHz: 1.2, depth: 0.4, wet: 0.3)
        ]

        for effect in valid {
            let compiled = try SoundCompiler().compile(
                Synthesizer(.sine).effect(effect)
            )
            #expect(compiled.renderNodes.last == CompiledRenderNode.effect(input: 0, effect: effect))
        }

        let invalid: [AudioEffect] = [
            .equalizer(frequencyHz: 0, gainDecibels: 0, q: 1),
            .filter(kind: .lowPass, cutoffHz: 1, resonance: -1),
            .compressor(thresholdDecibels: .infinity, ratio: 2),
            .compressor(thresholdDecibels: -10, ratio: 0.5),
            .distortion(drive: -1),
            .delay(time: .zero, feedback: 0.2, wet: 0.2),
            .delay(time: .quarter, feedback: 1, wet: 0.2),
            .reverb(roomSize: 1.1, wet: 0.2),
            .chorus(rateHz: 0, depth: 0.2, wet: 0.2),
            .chorus(rateHz: 1, depth: 0.2, wet: -0.1)
        ]

        for effect in invalid {
            #expect(throws: (any Error).self) {
                try SoundCompiler().compile(Synthesizer(.sine).effect(effect))
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testTrackScopeAndTempoIndependence() throws {
        struct Song: Music {
            var body: some Sound {
                Track("drums") {
                    Sample("kick")
                }
                Synthesizer(.sine)
            }
        }

        let compiled = try SoundCompiler().compile(Song())
        #expect(compiled.tracks.count == 1)
        #expect(compiled.events[0].trackID == compiled.tracks[0].id)
        #expect(compiled.events[1].trackID == nil)

        let slow = try Tempo(beatsPerMinute: 60)
        let fast = try Tempo(beatsPerMinute: 120)
        #expect(abs((try slow.seconds(for: compiled.extent)) - (1)) < 0.000_001)
        #expect(abs((try fast.seconds(for: compiled.extent)) - (0.5)) < 0.000_001)
        let expectedEvents = try SoundCompiler().compile(Song()).events
        #expect(compiled.events == expectedEvents)
    }

    @Test(.timeLimit(.minutes(3)))
    func testTypedParsingParametersAndCompilerBounds() throws {
        #expect {
            try RhythmPattern(validating: "")
        } throws: { error in
            error as? RhythmPatternError == .emptyInput
        }
        #expect {
            try RhythmPattern(validating: "x nope")
        } throws: { error in
            error as? RhythmPatternError == .invalidToken(token: "nope", index: 1, offset: 2)
        }
        #expect(throws: (any Error).self) {
            try Envelope(
                attackSeconds: -1,
                decaySeconds: 0,
                sustainLevel: 1,
                releaseSeconds: 0
            )
        }
        #expect(throws: (any Error).self) {
            try SampleRegion(startFraction: 0.8, endFraction: 0.2)
        }
        #expect(throws: (any Error).self) {
            try Unison(voices: 17, detuneCents: 1)
        }

        let limits = try SoundCompiler.Limits(
            maximumDepth: 10,
            maximumEvents: 1,
            maximumTracks: 10,
            maximumSources: 10,
            maximumRenderNodes: 10
        )
        struct Many: Sound {
            var body: some Sound {
                Sample("a")
                Sample("b")
            }
        }
        #expect {
            try SoundCompiler(limits: limits).compile(Many())
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 1)
        }

        let invalidSounds: [() throws -> CompiledSound] = [
            { try SoundCompiler().compile(Synthesizer(.sine).velocity(0)) },
            { try SoundCompiler().compile(Synthesizer(.sine).velocity(128)) },
            { try SoundCompiler().compile(Synthesizer(.sine).gate(0)) },
            { try SoundCompiler().compile(Synthesizer(.sine).gate(.infinity)) },
            { try SoundCompiler().compile(Synthesizer(.sine).fast(0)) },
            { try SoundCompiler().compile(Synthesizer(.sine).slow(0)) },
            { try SoundCompiler().compile(Synthesizer(.sine).repeated(0)) },
            { try SoundCompiler().compile(Synthesizer(.sine).notes([])) }
        ]
        for compile in invalidSounds {
            #expect(throws: (any Error).self) {
                try compile()
            }
        }

        struct TrackPair: Sound {
            var body: some Sound {
                Track("first") { Sample("a") }
                Track("second") { Sample("b") }
            }
        }
        let trackLimit = try SoundCompiler.Limits(maximumTracks: 1)
        #expect {
            try SoundCompiler(limits: trackLimit).compile(TrackPair())
        } throws: { error in
            error as? SoundCompilationError == .maximumTracksExceeded(limit: 1)
        }

        let sourceLimit = try SoundCompiler.Limits(maximumSources: 1)
        #expect {
            try SoundCompiler(limits: sourceLimit).compile(Many())
        } throws: { error in
            error as? SoundCompilationError == .maximumSourcesExceeded(limit: 1)
        }

        struct Nested: Sound {
            var body: some Sound {
                Track("outer") {
                    Track("inner") {
                        Sample("nested")
                    }
                }
            }
        }
        let depthLimit = try SoundCompiler.Limits(maximumDepth: 1)
        #expect {
            try SoundCompiler(limits: depthLimit).compile(Nested())
        } throws: { error in
            error as? SoundCompilationError == .maximumDepthExceeded(limit: 1)
        }
    }
}
