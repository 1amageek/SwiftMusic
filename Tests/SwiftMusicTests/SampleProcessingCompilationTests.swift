import Foundation
import SwiftMusic
import Testing

struct SampleProcessingCompilationTests {
    private func file() throws -> Sample {
        try Sample(file: URL(fileURLWithPath: "/tmp/swiftmusic-p061.caf"))
    }

    @Test(.timeLimit(.minutes(3)))
    func descriptorsValidateAndRetainImmutableValues() throws {
        let standard = GranularPlayback.standard
        #expect(standard.grainDuration == .milliseconds(40))
        #expect(standard.overlap == 0.5)
        #expect(standard.positionJitter == 0)
        #expect(standard.seed == 0)

        let playback = try GranularPlayback(
            grainDuration: .milliseconds(80),
            overlap: 0.25,
            positionJitter: 0.4,
            seed: 17
        )
        #expect(playback.grainDuration == .milliseconds(80))
        #expect(playback.overlap == 0.25)
        #expect(playback.positionJitter == 0.4)
        #expect(playback.seed == 17)

        #expect(throws: SampleDescriptorError.invalidSlice(index: 2, count: 2)) {
            try SampleSlice(index: 2, count: 2)
        }
        #expect(throws: SampleDescriptorError.invalidChopCount(0)) {
            try file().chopped(into: 0)
        }
        #expect(throws: SampleDescriptorError.invalidGranularDuration) {
            try GranularPlayback(grainDuration: .zero, overlap: 0.5, positionJitter: 0, seed: 0)
        }
        #expect(throws: SampleDescriptorError.invalidGranularOverlap(1)) {
            try GranularPlayback(grainDuration: .milliseconds(40), overlap: 1, positionJitter: 0, seed: 0)
        }
        #expect(throws: SampleDescriptorError.invalidGranularJitter(-0.1)) {
            try GranularPlayback(grainDuration: .milliseconds(40), overlap: 0.5, positionJitter: -0.1, seed: 0)
        }
        #expect(throws: SampleDescriptorError.invalidStretchDuration(.zero)) {
            try file().sampleStretch(to: .zero)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func sourceSliceSubdividesCurrentRegionAndOuterRegionReplacesIt() throws {
        let compiler = SoundCompiler()
        let initial = try SampleRegion(startFraction: 0.2, endFraction: 0.8)
        let slice = try SampleSlice(index: 1, count: 3)

        let subdivided = try compiler.compile(file().sampleRegion(initial).sampleSlice(slice))
        let selected = try #require(subdivided.sources[0].sampleRegion)
        #expect(abs(selected.startFraction - 0.4) < 0.000_000_000_001)
        #expect(abs(selected.endFraction - 0.6) < 0.000_000_000_001)

        let outer = try SampleRegion(startFraction: 0.1, endFraction: 0.9)
        let replaced = try compiler.compile(file().sampleSlice(slice).sampleRegion(outer))
        #expect(replaced.sources[0].sampleRegion == outer)
    }

    @Test(.timeLimit(.minutes(3)))
    func choppedEventsPartitionTimeAndPreserveProvenance() throws {
        let compiled = try SoundCompiler().compile(
            file().rhythm("x x").chopped(into: 2)
        )

        #expect(compiled.events.map(\.start) == [.zero, .quarter, .half, .beats(3)])
        #expect(compiled.events.map(\.duration) == Array(repeating: .quarter, count: 4))
        #expect(compiled.events.map(\.sampleSlice?.index) == [0, 1, 0, 1])
        #expect(compiled.events.map(\.sampleSlice?.count) == [2, 2, 2, 2])
        #expect(compiled.events.map(\.patternStepIndex) == [0, 0, 1, 1])
        #expect(compiled.events.allSatisfy { $0.sourceID == 0 })

        let neutral = try SoundCompiler().compile(file().chopped(into: 1))
        let baseline = try SoundCompiler().compile(file())
        #expect(neutral.events == baseline.events)
    }

    @Test(.timeLimit(.minutes(3)))
    func nestedChopsComposeEventSlicesAndRejectExcessiveCombinedCounts() throws {
        let nested = try SoundCompiler().compile(file().chopped(into: 2).chopped(into: 2))
        #expect(nested.events.map(\.sampleSlice?.index) == [0, 1, 2, 3])
        #expect(nested.events.map(\.sampleSlice?.count) == [4, 4, 4, 4])

        #expect(throws: SampleDescriptorError.invalidSlice(index: 0, count: 1_056)) {
            try SoundCompiler().compile(file().chopped(into: 33).chopped(into: 32))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func choppedLiveCopiesRemainWithinTheSameRecurrenceWindow() throws {
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(4))
        let compiled = try SoundCompiler().compile(
            file().rhythm("x x").chopped(into: 2),
            liveLoop: policy
        )

        #expect(compiled.playbackMode == .seamlessLoop)
        #expect(compiled.extent == .beats(4))
        #expect(compiled.events.count == 4)
        #expect(compiled.events.map(\.start) == [.zero, .quarter, .half, .beats(3)])
        #expect(compiled.events.allSatisfy { $0.sampleSlice?.count == 2 })
    }

    @Test(.timeLimit(.minutes(3)))
    func granularAndStretchSettingsReplaceEarlierDeclarations() throws {
        let first = try GranularPlayback(
            grainDuration: .milliseconds(40), overlap: 0.5, positionJitter: 0.1, seed: 1
        )
        let second = try GranularPlayback(
            grainDuration: .milliseconds(90), overlap: 0.2, positionJitter: 0.3, seed: 2
        )
        let compiled = try SoundCompiler().compile(
            file()
                .granular(first)
                .sampleStretch(to: .half)
                .granular(second)
                .sampleStretch(to: .whole)
        )

        #expect(compiled.sources[0].granularPlayback == second)
        #expect(compiled.sources[0].sampleStretchDuration == .whole)
    }

    @Test(.timeLimit(.minutes(3)))
    func decodedOnlySettingsRejectProceduralSourcesAndBoundExpansion() throws {
        let playback = try GranularPlayback(
            grainDuration: .milliseconds(40), overlap: 0.5, positionJitter: 0, seed: 0
        )
        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Sample slicing requires a file or sample bank source"
        )) {
            try SoundCompiler().compile(Sample("kick").sampleSlice(try SampleSlice(index: 0, count: 2)))
        }
        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Granular playback requires a file or sample bank source"
        )) {
            try SoundCompiler().compile(Sample("kick").granular(playback))
        }
        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Sample stretch requires a file or sample bank source"
        )) {
            try SoundCompiler().compile(Sample("kick").sampleStretch(to: .whole))
        }

        let limits = try SoundCompiler.Limits(maximumEvents: 3)
        #expect(throws: SoundCompilationError.maximumEventsExceeded(limit: 3)) {
            try SoundCompiler(limits: limits).compile(file().rhythm("x x").chopped(into: 2))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func choppedExpansionRejectsPendingDuckRuleOverflowBeforeAllocation() throws {
        let sound = try file()
            .duck(targetBus: "room", depth: try Decibels(value: -3), attack: .zero, recovery: .seconds(1))
            .duck(targetBus: "room", depth: try Decibels(value: -6), attack: .zero, recovery: .seconds(1))
        #expect(throws: SoundCompilationError.invalidParameter(
            "Maximum event duck rule count exceeded"
        )) {
            try SoundCompiler().compile(sound.chopped(into: 1_024))
        }
    }
}
