import Foundation
import Testing
import SwiftMusic

struct SoundPipelineTests {
    @Test(.timeLimit(.minutes(3)))
    func testEventModifiersComposeInWrittenOrderWithoutChangingSourceGraph() throws {
        let rhythm = try RhythmPattern(validating: "x ~ x ~")
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
        #expect(compiled.events.compactMap(\.pitch?.midiNote) == [72, 75, 79, 74, 77, 81, 72, 75, 79, 74, 77, 81])
        let starts = try [(1, 4), (5, 4), (5, 2), (7, 2)].map {
            try MusicalTime(numerator: UInt64($0.0), denominator: UInt64($0.1))
        }
        for (index, event) in compiled.events.enumerated() {
            #expect(event.start == starts[index / 3])
            #expect(event.duration == .eighth)
            #expect(event.velocity == 100)
            #expect(event.gate == 0.375)
            #expect(event.sourceID == 0)
        }
        let expectedExtent = try MusicalTime(numerator: 9, denominator: 2)
        #expect(compiled.extent == expectedExtent)
        #expect(compiled.renderNodes == [.source(sourceID: 0)])
        let expectedCompiled = try SoundCompiler().compile(sound)
        #expect(compiled == expectedCompiled)

        let firstOffset = try SoundCompiler().compile(Sample("kick").offset(.quarter).fast(2))
        let lastOffset = try SoundCompiler().compile(Sample("kick").fast(2).offset(.quarter))
        #expect(firstOffset.events[0].start == .eighth)
        #expect(lastOffset.events[0].start == .quarter)
    }

    @Test(.timeLimit(.minutes(3)))
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
        #expect(result.renderNodes == [
            .source(sourceID: 0),
            .effect(input: 0, effect: .distortion(drive: 0.6)),
            .source(sourceID: 1),
            .mix(inputs: [1, 2]),
            .track(input: 3, trackID: 0),
            .effect(input: 4, effect: reverb),
            .gain(input: 5, value: 0.8),
            .pan(input: 6, value: -0.25),
            .send(input: 7, bus: "room", level: 0.3),
            .output(input: 8, bus: "main")
        ])
        #expect(result.rootNodeIDs == [9])
        #expect(result.events.map(\.trackID) == [0, 0])
        #expect(result.events.map(\.sourceID) == [0, 1])
    }

    @Test(.timeLimit(.minutes(3)))
    func testTrackBoundaryPreservesSourceSettingsInTheirSubtree() throws {
        struct Pair: Sound {
            var body: some Sound {
                Sample("kick")
                Synthesizer(.saw).offset(.eighth)
            }
        }
        let compiler = SoundCompiler()
        let plain = try compiler.compile(Pair())
        let grouped = try compiler.compile(Track("group") { Pair() })
        #expect(grouped.renderNodes == [
            .source(sourceID: 0),
            .source(sourceID: 1),
            .mix(inputs: [0, 1]),
            .track(input: 2, trackID: 0)
        ])
        #expect(grouped.rootNodeIDs == [3])
        #expect(plain.events.map(\.start) == grouped.events.map(\.start))
        #expect(plain.events.map(\.duration) == grouped.events.map(\.duration))
        #expect(plain.extent == grouped.extent)

        let envelope = try Envelope(attackSeconds: 0.01, decaySeconds: 0.1,
                                    sustainLevel: 0.8, releaseSeconds: 0.2)
        let region = try SampleRegion(startFraction: 0.25, endFraction: 0.75)
        let unison = try Unison(voices: 3, detuneCents: 7)
        let tuning = try Tuning(referencePitch: Pitch(midiNote: 69), frequencyHz: 442)
        let fileSample = try Sample(file: URL(fileURLWithPath: "/tmp/kick.caf"))
        let configured = try compiler.compile(Track("configured") {
            fileSample.sampleRegion(region)
            Synthesizer(.saw).unison(unison).tuning(tuning)
        }.envelope(envelope))
        #expect(configured.sources.map(\.envelope) == [envelope, envelope])
        #expect(configured.sources[0].sampleRegion == region)
        #expect(configured.sources[0].unison == nil)
        #expect(configured.sources[0].tuning == nil)
        #expect(configured.sources[1].sampleRegion == nil)
        #expect(configured.sources[1].unison == unison)
        #expect(configured.sources[1].tuning == tuning)
        #expect {
            try compiler.compile(Pair().unison(unison))
        } throws: { error in
            guard case SoundCompilationError.unsupportedSourceSetting = error else {
                Issue.record("Expected unsupported source setting, received \(error)")
                return false
            }
            return true
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func testExpansionAndGraphBudgetsAreGlobalAndCheckedBeforeAllocation() throws {
        let limited = SoundCompiler(limits: try .init(maximumEvents: 5))
        #expect {
            try limited.compile(Track("group") {
                Sample("a").repeated(3)
                Sample("b").repeated(3)
            })
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 5)
        }
        #expect {
            try limited.compile(Sample("a").repeated(Int.max))
        } throws: { error in
            error as? SoundCompilationError == .maximumEventsExceeded(limit: 5)
        }
        let oneNode = SoundCompiler(limits: try .init(maximumRenderNodes: 1))
        #expect {
            try oneNode.compile(Sample("a").gain(0.5))
        } throws: { error in
            error as? SoundCompilationError == .maximumRenderNodesExceeded(limit: 1)
        }
        let silent = Sample("a")
            .rhythm(try RhythmPattern(validating: "~"), cycle: .eighth)
            .repeated(Int.max)
        let result = try limited.compile(silent)
        #expect(result.events.isEmpty)
        let expectedExtent = try MusicalTime.eighth.multiplied(by: UInt64(Int.max))
        #expect(result.extent == expectedExtent)
    }

    @Test(.timeLimit(.minutes(3)))
    func testTempoDoesNotAlterCompiledEventsOrAudioPlan() throws {
        let sound = Sample("kick")
            .rhythm(try RhythmPattern(validating: "x ~ x ~"), cycle: .whole)
            .effect(.delay(time: .eighth, feedback: 0.2, wet: 0.3))
        let compiled = try SoundCompiler().compile(sound)
        #expect(try Tempo(beatsPerMinute: 60).seconds(for: compiled.extent) == 4)
        #expect(try Tempo(beatsPerMinute: 120).seconds(for: compiled.extent) == 2)
        let expectedCompiled = try SoundCompiler().compile(sound)
        #expect(compiled == expectedCompiled)
    }
    @Test(.timeLimit(.minutes(3)))
    func testOutputSinksStaySeparateAndRejectFurtherAudioProcessing() throws {
        let sound = Track("routed") {
            Sample("a").output("bus")
            Sample("b")
            Sample("c")
        }
        let compiler = SoundCompiler()
        let compiled = try compiler.compile(sound)
        #expect(compiled.renderNodes == [
            .source(sourceID: 0), .output(input: 0, bus: "bus"),
            .source(sourceID: 1), .source(sourceID: 2), .mix(inputs: [2, 3]),
            .track(input: 4, trackID: 0)
        ])
        #expect(compiled.rootNodeIDs == [1, 5])
        for modified in [sound.gain(1), sound.pan(0), sound.muted(),
                         sound.send(to: "room", level: 1), sound.output("main"),
                         sound.effect(.distortion(drive: 1))] {
            #expect {
                try compiler.compile(modified)
            } throws: { error in
                guard case SoundCompilationError.invalidParameter = error else {
                    Issue.record("Expected invalid processing order")
                    return false
                }
                return true
            }
        }
        #expect(try compiler.compile(sound.offset(.quarter)).events.first?.start == .quarter)
    }

}
