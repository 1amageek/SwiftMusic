import XCTest
import SwiftMusic

final class SoundCompositionTests: XCTestCase {
    private func pitch(_ value: UInt8) throws -> Pitch {
        try Pitch(midiNote: value)
    }

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

        XCTAssertEqual(compiled.events.count, 2)
        XCTAssertEqual(compiled.events.map(\.start), [.zero, .zero])
        XCTAssertEqual(compiled.events.map(\.duration), [.quarter, .quarter])
        XCTAssertEqual(compiled.events[0].pitch, nil)
        XCTAssertEqual(compiled.events[1].pitch, .middleC)
        XCTAssertEqual(compiled.sources.map(\.id), [0, 1])
        XCTAssertEqual(compiled.sources.map(\.kind), [.sample("kick"), .synthesizer(.sine)])
        XCTAssertEqual(compiled.tracks.map(\.name), ["empty"])
    }

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
        XCTAssertEqual(included.sources.map(\.kind), [
            .sample("first"), .sample("optional"), .sample("available"),
            .sample("loop-a"), .sample("loop-b")
        ])

        let excluded = try SoundCompiler().compile(Branches(includeFirst: false))
        XCTAssertEqual(excluded.sources.map(\.kind), [
            .sample("alternate"), .sample("available"),
            .sample("loop-a"), .sample("loop-b")
        ])
    }

    func testRhythmOffsetRepeatFastSlowAndTrailingExtent() throws {
        let pattern = try RhythmPattern(validating: "x ~ x")
        let rhythmic = Sample("hat").rhythm(pattern, cycle: .whole)
        let compiled = try SoundCompiler().compile(rhythmic)

        XCTAssertEqual(compiled.events.count, 2)
        XCTAssertEqual(compiled.events.map(\.start), [
            .zero,
            try MusicalTime(numerator: 8, denominator: 3)
        ])
        XCTAssertEqual(compiled.events.map(\.duration), [
            try MusicalTime(numerator: 4, denominator: 3),
            try MusicalTime(numerator: 4, denominator: 3)
        ])
        XCTAssertEqual(compiled.extent, .whole)

        let repeated = try SoundCompiler().compile(
            Sample("hat").repeated(3)
        )
        XCTAssertEqual(repeated.events.map(\.start), [.zero, .quarter, .half])
        XCTAssertEqual(repeated.extent, try .quarter.multiplied(by: 3))

        let fast = try SoundCompiler().compile(Sample("hat").fast(2))
        XCTAssertEqual(fast.events[0].duration, .eighth)
        XCTAssertEqual(fast.extent, .eighth)

        let slow = try SoundCompiler().compile(Sample("hat").slow(2))
        XCTAssertEqual(slow.events[0].duration, .half)
        XCTAssertEqual(slow.extent, .half)

        let shifted = try SoundCompiler().compile(
            Sample("hat").offset(.half)
        )
        XCTAssertEqual(shifted.events[0].start, .half)
        XCTAssertEqual(shifted.extent, try .half.adding(.quarter))
    }

    func testPitchHarmonyAndEventOrder() throws {
        let sound = Synthesizer(.sine)
            .notes([try pitch(60)])
            .chord(.major)
            .transpose(1)
        let compiled = try SoundCompiler().compile(sound)

        XCTAssertEqual(compiled.events.map { $0.pitch?.midiNote }, [61, 65, 68])

        let cycling = try SoundCompiler().compile(
            Synthesizer(.square).repeated(3).notes([try pitch(60), try pitch(64)])
        )
        XCTAssertEqual(cycling.events.map { $0.pitch?.midiNote }, [60, 64, 60])

        XCTAssertThrowsError(
            try SoundCompiler().compile(Sample("noise").transpose(1))
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .missingPitch)
        }

        XCTAssertThrowsError(
            try SoundCompiler().compile(Synthesizer(.sine).notes([try pitch(127)]).transpose(1))
        ) { error in
            XCTAssertEqual(error as? SoundCompilationError, .pitchOutOfRange)
        }
    }

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
            XCTAssertEqual(compiled.events.compactMap(\.pitch?.midiNote), notes)
        }
    }

    func testExpressionModifiersPreserveTime() throws {
        let sound = Synthesizer(.sine)
            .dynamic(.ff)
            .velocity(100)
            .gate(0.5)
            .staccato()
        let compiled = try SoundCompiler().compile(sound)

        XCTAssertEqual(compiled.events[0].velocity, 100)
        XCTAssertEqual(compiled.events[0].gate, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(compiled.events[0].duration, .quarter)
        XCTAssertEqual(compiled.extent, .quarter)
    }

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

        let sample = try SoundCompiler().compile(
            Sample("piano")
                .tuning(tuning)
                .envelope(envelope)
                .sampleRegion(region)
        )
        XCTAssertEqual(sample.sources[0].tuning, tuning)
        XCTAssertEqual(sample.sources[0].envelope, envelope)
        XCTAssertEqual(sample.sources[0].sampleRegion, region)
        XCTAssertNil(sample.sources[0].unison)

        let synth = try SoundCompiler().compile(
            Synthesizer(.saw)
                .tuning(tuning)
                .envelope(envelope)
                .unison(unison)
        )
        XCTAssertEqual(synth.sources[0].tuning, tuning)
        XCTAssertEqual(synth.sources[0].envelope, envelope)
        XCTAssertEqual(synth.sources[0].unison, unison)

        XCTAssertThrowsError(
            try SoundCompiler().compile(Sample("piano").unison(unison))
        ) { error in
            guard case .unsupportedSourceSetting = error as? SoundCompilationError else {
                return XCTFail("Expected unsupported source setting, received \(error)")
            }
        }
    }

    func testEffectsMixAndRoutingRenderPlanOrder() throws {
        let delay = AudioEffect.delay(time: .quarter, feedback: 0.2, wet: 0.4)
        let reverb = AudioEffect.reverb(roomSize: 0.5, wet: 0.3)
        let chain = Synthesizer(.sine)
            .effect(delay)
            .effect(reverb)
        let compiled = try SoundCompiler().compile(chain)

        XCTAssertEqual(compiled.renderNodes.count, 3)
        XCTAssertEqual(compiled.rootNodeIDs, [2])
        guard case .source(sourceID: 0) = compiled.renderNodes[0] else {
            return XCTFail("expected source node")
        }
        guard case .effect(input: 0, effect: delay) = compiled.renderNodes[1] else {
            return XCTFail("expected first effect node")
        }
        guard case .effect(input: 1, effect: reverb) = compiled.renderNodes[2] else {
            return XCTFail("expected second effect node")
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
        XCTAssertEqual(mixed.rootNodeIDs, [3])
        XCTAssertEqual(mixed.renderNodes[2], CompiledRenderNode.mix(inputs: [0, 1]))
        XCTAssertEqual(
            mixed.renderNodes[3],
            CompiledRenderNode.effect(input: 2, effect: .distortion(drive: 0.5))
        )

        let routed = try SoundCompiler().compile(
            Synthesizer(.triangle)
                .gain(0.5)
                .pan(-0.25)
                .muted()
                .send(to: "reverb", level: 0.2)
                .output("main")
        )
        XCTAssertEqual(routed.renderNodes.count, 6)
        XCTAssertEqual(routed.rootNodeIDs, [5])
    }

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
            XCTAssertEqual(
                compiled.renderNodes.last,
                CompiledRenderNode.effect(input: 0, effect: effect)
            )
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
            XCTAssertThrowsError(try SoundCompiler().compile(
                Synthesizer(.sine).effect(effect)
            ))
        }
    }

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
        XCTAssertEqual(compiled.tracks.count, 1)
        XCTAssertEqual(compiled.events[0].trackID, compiled.tracks[0].id)
        XCTAssertNil(compiled.events[1].trackID)

        let slow = try Tempo(beatsPerMinute: 60)
        let fast = try Tempo(beatsPerMinute: 120)
        XCTAssertEqual(try slow.seconds(for: compiled.extent), 1, accuracy: 0.000_001)
        XCTAssertEqual(try fast.seconds(for: compiled.extent), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(compiled.events, try SoundCompiler().compile(Song()).events)
    }

    func testTypedParsingParametersAndCompilerBounds() throws {
        XCTAssertThrowsError(try RhythmPattern(validating: "")) { error in
            XCTAssertEqual(error as? RhythmPatternError, .emptyInput)
        }
        XCTAssertThrowsError(try RhythmPattern(validating: "x nope")) { error in
            XCTAssertEqual(
                error as? RhythmPatternError,
                .invalidToken(token: "nope", index: 1)
            )
        }
        XCTAssertThrowsError(try Envelope(
            attackSeconds: -1,
            decaySeconds: 0,
            sustainLevel: 1,
            releaseSeconds: 0
        ))
        XCTAssertThrowsError(try SampleRegion(startFraction: 0.8, endFraction: 0.2))
        XCTAssertThrowsError(try Unison(voices: 17, detuneCents: 1))

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
        XCTAssertThrowsError(try SoundCompiler(limits: limits).compile(Many())) { error in
            XCTAssertEqual(error as? SoundCompilationError, .maximumEventsExceeded(limit: 1))
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
            XCTAssertThrowsError(try compile())
        }

        struct TrackPair: Sound {
            var body: some Sound {
                Track("first") { Sample("a") }
                Track("second") { Sample("b") }
            }
        }
        let trackLimit = try SoundCompiler.Limits(maximumTracks: 1)
        XCTAssertThrowsError(try SoundCompiler(limits: trackLimit).compile(TrackPair())) { error in
            XCTAssertEqual(error as? SoundCompilationError, .maximumTracksExceeded(limit: 1))
        }

        let sourceLimit = try SoundCompiler.Limits(maximumSources: 1)
        XCTAssertThrowsError(try SoundCompiler(limits: sourceLimit).compile(Many())) { error in
            XCTAssertEqual(error as? SoundCompilationError, .maximumSourcesExceeded(limit: 1))
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
        XCTAssertThrowsError(try SoundCompiler(limits: depthLimit).compile(Nested())) { error in
            XCTAssertEqual(error as? SoundCompilationError, .maximumDepthExceeded(limit: 1))
        }
    }
}
