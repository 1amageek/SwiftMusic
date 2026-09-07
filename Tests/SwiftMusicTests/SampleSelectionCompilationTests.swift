import Foundation
import SwiftMusic
import Testing

struct SampleSelectionCompilationTests {
    private func asset(_ key: String) throws -> SampleAsset {
        try SampleAsset(
            key: key,
            fileURL: URL(fileURLWithPath: "/tmp/swiftmusic-(key).caf")
        )
    }

    private func bank() throws -> SampleBank {
        try SampleBank([try asset("kick"), try asset("snare")])
    }

    @Test(.timeLimit(.minutes(3)))
    func descriptorsPreserveExplicitOrderAndRejectUnreachableKeys() throws {
        let ordered = try bank()
        #expect(ordered.assets.map(\.key) == ["kick", "snare"])
        #expect(Sample(bank: ordered) == Sample(bank: ordered))

        #expect(throws: SampleDescriptorError.emptyBank) {
            try SampleBank([])
        }
        #expect(throws: SampleDescriptorError.duplicateKey("kick")) {
            try SampleBank([try asset("kick"), try asset("kick")])
        }
        #expect(throws: SampleDescriptorError.invalidKey(index: 0)) {
            try SampleAsset(key: "x*2", fileURL: URL(fileURLWithPath: "/tmp/repeated.caf"))
        }
        #expect(throws: SampleDescriptorError.invalidFileURL) {
            try SampleAsset(key: "kick", fileURL: URL(string: "https://example.com/kick.caf")!)
        }
        #expect(throws: SampleDescriptorError.invalidFileURL) {
            try Sample(file: URL(string: "file:relative.caf")!)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func finiteSelectionSamplesKeysAtCurrentEventOnsets() throws {
        let compiled = try SoundCompiler().compile(
            Sample(bank: try bank())
                .rhythm("x x")
                .sampleSelection(try SampleSelectionPattern(validating: "kick snare"))
        )

        #expect(compiled.sources[0].kind == .sampleBank(try bank()))
        #expect(compiled.events.map(\.sampleKey) == ["kick", "snare"])
        #expect(compiled.events.map(\.start) == [.zero, .half])
        #expect(compiled.events.allSatisfy { $0.pitch == .middleC })
    }

    @Test(.timeLimit(.minutes(3)))
    func preGeneratorSelectionIsSeededAndPostGeneratorSelectionIsRecurring() throws {
        let source = Sample(bank: try bank())
        let preGenerator = try SoundCompiler().compile(
            source
                .sampleSelection(try SampleSelectionPattern(validating: "snare"))
                .rhythm("x x")
        )
        #expect(preGenerator.events.map(\.sampleKey) == ["snare", "snare"])

        let policy = try LiveLoopPolicy(
            beatsPerBar: 4,
            maximumBeats: MusicalTime(numerator: 4, denominator: 1)
        )
        let postGenerator = try SoundCompiler().compile(
            source
                .rhythm("x x")
                .sampleSelection(try SampleSelectionPattern(validating: "kick snare")),
            liveLoop: policy
        )
        #expect(postGenerator.events.map(\.sampleKey) == ["kick", "snare"])
        #expect(postGenerator.events.map(\.start) == [.zero, .half])
    }

    @Test(.timeLimit(.minutes(3)))
    func selectionValidatesUnknownKeysAndEmptySubtreesBeforeEmission() throws {
        let source = Sample(bank: try bank())
        #expect(throws: SoundCompilationError.unknownSampleKey(key: "hat", utf8Offset: 5)) {
            try SoundCompiler().compile(
                source.sampleSelection(try SampleSelectionPattern(validating: "kick hat"))
            )
        }
        #expect(throws: SoundCompilationError.unknownSampleKey(key: "hat", utf8Offset: 0)) {
            try SoundCompiler().compile(
                source.rhythm("~").sampleSelection(try SampleSelectionPattern(validating: "hat"))
            )
        }
        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Sample selection requires a sample bank source"
        )) {
            try SoundCompiler().compile(
                Sample(file: URL(fileURLWithPath: "/tmp/direct.caf"))
                    .sampleSelection(try SampleSelectionPattern(validating: "kick"))
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func fileTraversalSettingsReplaceEarlierValuesAndRejectProceduralSources() throws {
        let firstRegion = try SampleRegion(startFraction: 0.1, endFraction: 0.9)
        let secondRegion = try SampleRegion(startFraction: 0.2, endFraction: 0.8)
        let file = try Sample(file: URL(fileURLWithPath: "/tmp/direct.caf"))
        let configured = try SoundCompiler().compile(
            file.sampleRegion(firstRegion)
                .sampleRegion(secondRegion)
                .sampleReversed()
                .samplePlaybackRate(2)
        )
        #expect(configured.sources[0].sampleRegion == secondRegion)
        #expect(configured.sources[0].sampleReversed)
        #expect(configured.sources[0].samplePlaybackRate == 2)
        #expect(configured.events[0].sampleKey == nil)

        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Sample region requires a file or sample bank source"
        )) {
            try SoundCompiler().compile(Sample("kick").sampleRegion(secondRegion))
        }
        #expect(throws: SoundCompilationError.unsupportedSourceSetting(
            "Sample reversal requires a file or sample bank source"
        )) {
            try SoundCompiler().compile(Sample("kick").sampleReversed())
        }
        #expect(throws: SampleDescriptorError.invalidPlaybackRate(0)) {
            try Sample("kick").samplePlaybackRate(0)
        }
    }
}
