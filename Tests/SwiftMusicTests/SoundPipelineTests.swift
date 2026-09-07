import XCTest
import SwiftMusic

final class SoundPipelineTests: XCTestCase {
    func testEventModifiersComposeInWrittenOrderWithoutChangingSourceGraph() throws {
        let rhythm = try RhythmPattern("x ~ x ~")
        let c = try Pitch(midiNote: 60)
        let d = try Pitch(midiNote: 62)
        let sound = Synthesizer(.saw)
            .rhythm(rhythm, cycle: .whole)
            .notes([c, d])
            .transpose(12)
            .chord(.minor)
            .dynamic(.p)
            .velocity(100)
            .staccato()
            .gate(0.75)
            .staccato()
            .offset(.eighth)
            .fast(2)
            .repeated(2)
        let compiled = try SoundCompiler().compile(sound)
        XCTAssertEqual(compiled.events.compactMap(\.pitch?.midiNote),
                       [72, 75, 79, 74, 77, 81, 72, 75, 79, 74, 77, 81])
        let starts = try [(1, 4), (5, 4), (5, 2), (7, 2)].map {
            try MusicalTime(numerator: UInt64($0.0), denominator: UInt64($0.1))
        }
        for (index, event) in compiled.events.enumerated() {
            XCTAssertEqual(event.start, starts[index / 3])
            XCTAssertEqual(event.duration, .eighth)
            XCTAssertEqual(event.velocity, 100)
            XCTAssertEqual(event.gate, 0.375)
            XCTAssertEqual(event.sourceID, 0)
        }
        XCTAssertEqual(compiled.extent, try MusicalTime(numerator: 9, denominator: 2))
        XCTAssertEqual(compiled.renderNodes, [.source(sourceID: 0)])
        XCTAssertEqual(compiled, try SoundCompiler().compile(sound))

        let firstOffset = try SoundCompiler().compile(Sample("kick").offset(.quarter).fast(2))
        let lastOffset = try SoundCompiler().compile(Sample("kick").fast(2).offset(.quarter))
        XCTAssertEqual(firstOffset.events[0].start, .eighth)
        XCTAssertEqual(lastOffset.events[0].start, .quarter)
    }

    func testTrackPostMixEffectsAndRoutingRetainExactGraphOrder() throws {
        let reverb = AudioEffect.reverb(roomSize: 0.8, wet: 0.2)
        let sound = Track("drums") {
            Sample("kick").effect(.distortion(drive: 0.6))
            Sample("hat")
        }
        .effect(reverb)
        .gain(0.8)
        .pan(-0.25)
        .send(to: "room", level: 0.3)
        .output("main")
        let result = try SoundCompiler().compile(sound)
        XCTAssertEqual(result.renderNodes, [
            .source(sourceID: 0),
            .effect(input: 0, effect: .distortion(drive: 0.6)),
            .source(sourceID: 1),
            .mix(inputs: [1, 2]),
            .effect(input: 3, effect: reverb),
            .gain(input: 4, value: 0.8),
            .pan(input: 5, value: -0.25),
            .send(input: 6, bus: "room", level: 0.3),
            .output(input: 7, bus: "main")
        ])
        XCTAssertEqual(result.rootNodeIDs, [8])
        XCTAssertEqual(result.events.map(\.trackID), [0, 0])
        XCTAssertEqual(result.events.map(\.sourceID), [0, 1])
    }

    func testTrackIsTransparentAndSourceSettingsStayInTheirSubtree() throws {
        struct Pair: Sound {
            var body: some Sound {
                Sample("kick")
                Synthesizer(.saw).offset(.eighth)
            }
        }
        let compiler = SoundCompiler()
        let plain = try compiler.compile(Pair())
        let grouped = try compiler.compile(Track("group") { Pair() })
        XCTAssertEqual(plain.renderNodes, grouped.renderNodes)
        XCTAssertEqual(plain.events.map(\.start), grouped.events.map(\.start))
        XCTAssertEqual(plain.events.map(\.duration), grouped.events.map(\.duration))
        XCTAssertEqual(plain.extent, grouped.extent)

        let envelope = try Envelope(attackSeconds: 0.01, decaySeconds: 0.1,
                                    sustainLevel: 0.8, releaseSeconds: 0.2)
        let region = try SampleRegion(startFraction: 0.25, endFraction: 0.75)
        let unison = try Unison(voices: 3, detuneCents: 7)
        let tuning = try Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 442)
        let configured = try compiler.compile(Track("configured") {
            Sample("kick").sampleRegion(region)
            Synthesizer(.saw).unison(unison).tuning(tuning)
        }.envelope(envelope))
        XCTAssertEqual(configured.sources.map(\.envelope), [envelope, envelope])
        XCTAssertEqual(configured.sources[0].sampleRegion, region)
        XCTAssertNil(configured.sources[0].unison)
        XCTAssertNil(configured.sources[0].tuning)
        XCTAssertNil(configured.sources[1].sampleRegion)
        XCTAssertEqual(configured.sources[1].unison, unison)
        XCTAssertEqual(configured.sources[1].tuning, tuning)
        XCTAssertThrowsError(try compiler.compile(Pair().unison(unison))) {
            guard case SoundCompilationError.unsupportedSourceSetting = $0 else {
                return XCTFail("Expected unsupported source setting, received \($0)")
            }
        }
    }

    func testExpansionAndGraphBudgetsAreGlobalAndCheckedBeforeAllocation() throws {
        let limited = SoundCompiler(limits: try .init(maximumEvents: 5))
        XCTAssertThrowsError(try limited.compile(Track("group") {
            Sample("a").repeated(3)
            Sample("b").repeated(3)
        })) {
            XCTAssertEqual($0 as? SoundCompilationError, .maximumEventsExceeded(limit: 5))
        }
        XCTAssertThrowsError(try limited.compile(Sample("a").repeated(Int.max))) {
            XCTAssertEqual($0 as? SoundCompilationError, .maximumEventsExceeded(limit: 5))
        }
        let oneNode = SoundCompiler(limits: try .init(maximumRenderNodes: 1))
        XCTAssertThrowsError(try oneNode.compile(Sample("a").gain(0.5))) {
            XCTAssertEqual($0 as? SoundCompilationError, .maximumRenderNodesExceeded(limit: 1))
        }
        let silent = Sample("a")
            .rhythm(try RhythmPattern("~"), cycle: .eighth)
            .repeated(Int.max)
        let result = try limited.compile(silent)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.extent, try MusicalTime.eighth.multiplied(by: UInt64(Int.max)))
    }

    func testTempoDoesNotAlterCompiledEventsOrAudioPlan() throws {
        let sound = Sample("kick")
            .rhythm(try RhythmPattern("x ~ x ~"), cycle: .whole)
            .effect(.delay(time: .eighth, feedback: 0.2, wet: 0.3))
        let compiled = try SoundCompiler().compile(sound)
        XCTAssertEqual(try Tempo(beatsPerMinute: 60).seconds(for: compiled.extent), 4)
        XCTAssertEqual(try Tempo(beatsPerMinute: 120).seconds(for: compiled.extent), 2)
        XCTAssertEqual(compiled, try SoundCompiler().compile(sound))
    }
    func testOutputSinksStaySeparateAndRejectFurtherAudioProcessing() throws {
        let sound = Track("routed") {
            Sample("a").output("bus")
            Sample("b")
            Sample("c")
        }
        let compiler = SoundCompiler()
        let compiled = try compiler.compile(sound)
        XCTAssertEqual(compiled.renderNodes, [
            .source(sourceID: 0), .output(input: 0, bus: "bus"),
            .source(sourceID: 1), .source(sourceID: 2), .mix(inputs: [2, 3])
        ])
        XCTAssertEqual(compiled.rootNodeIDs, [1, 4])
        for modified in [sound.gain(1), sound.pan(0), sound.muted(),
                         sound.send(to: "room", level: 1), sound.output("main"),
                         sound.effect(.distortion(drive: 1))] {
            XCTAssertThrowsError(try compiler.compile(modified)) {
                guard case SoundCompilationError.invalidParameter = $0 else {
                    return XCTFail("Expected invalid processing order")
                }
            }
        }
        XCTAssertEqual(try compiler.compile(sound.offset(.quarter)).events.first?.start, .quarter)
    }

}
