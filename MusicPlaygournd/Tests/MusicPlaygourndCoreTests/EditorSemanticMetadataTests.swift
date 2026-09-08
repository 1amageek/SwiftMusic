import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct EditorSemanticMetadataTests {
    private func bank() throws -> SampleBank {
        try SampleBank([
            try SampleAsset(key: "kick", fileURL: URL(fileURLWithPath: "/tmp/kick.caf")),
            try SampleAsset(key: "snare", fileURL: URL(fileURLWithPath: "/tmp/snare.caf"))
        ])
    }

    @Test(.timeLimit(.minutes(3)))
    func compilerRetainsUnicodeSafeBankSiteAndBoundedCandidates() throws {
        let source = "// 音符\nstruct Session: Music {\n  var body: some Sound {\n    Sample(bank: bank).sampleSelection(\"kick snare\")\n  }\n}"
        let compiled = try SoundCompiler().compile(
            Sample(bank: try bank()).sampleSelection(
                try SampleSelectionPattern(validating: "kick snare"),
                fileID: "Session.swift",
                line: 4,
                column: 33
            )
        )
        let metadata = try EditorSemanticMetadata(sound: compiled, source: source, revision: 41)
        let storedBank = try #require(metadata.sampleBanks.first)
        #expect(storedBank.sourceID == 0)
        #expect(storedBank.displayName == "kick.caf")
        #expect(storedBank.values == ["kick", "snare"])
        let site = try #require(metadata.sampleCompletionSites.first)
        #expect((source as NSString).substring(with: site.contentRange) == "kick snare")
        let candidates = metadata.sampleCompletions(sourceID: 0, prefix: "sn")
        #expect(candidates.count == 1)
        #expect(candidates[0].label == "snare")
        #expect(candidates[0].replacementRange == site.contentRange)
        #expect(metadata.revision == 41)
    }

    @Test(.timeLimit(.minutes(3)))
    func metadataUsesAnchoredSameLineLiteralAndRejectsForeignOrAmbiguousAnchors() throws {
        let pattern: SampleSelectionPattern = "kick"
        let first = Sample(bank: try bank()).sampleSelection(
            pattern, fileID: "Session.swift", line: 3, column: 24
        )
        let second = Sample(bank: try bank()).sampleSelection(
            pattern, fileID: "Session.swift", line: 3, column: 68
        )
        let sound = SoundBuilder.buildBlock(
            SoundBuilder.buildExpression(first),
            SoundBuilder.buildExpression(second)
        )
        let source = "struct Session: Music {\n  var body: some Sound {\n    Sample(bank: bank).sampleSelection(\"kick\"); Sample(bank: bank).sampleSelection(\"kick\")\n  }\n}"
        let compiled = try SoundCompiler().compile(sound)
        let metadata = try EditorSemanticMetadata(sound: compiled, source: source, revision: 43)
        #expect(metadata.sampleCompletionSites.count == 2)
        let ranges = metadata.sampleCompletionSites.map(\.contentRange)
        #expect(ranges[0] != ranges[1])
        #expect(ranges.allSatisfy { (source as NSString).substring(with: $0) == "kick" })

        let foreign = Sample(bank: try bank()).sampleSelection(
            pattern, fileID: "Other.swift", line: 3, column: 24
        )
        let foreignMetadata = try EditorSemanticMetadata(
            sound: try SoundCompiler().compile(foreign), source: source, revision: 44
        )
        #expect(foreignMetadata.sampleCompletionSites.isEmpty)
        #expect(SourceAnchorLocations.literalArgument(
            source: source, fileID: "Session.swift", line: 3, column: 1,
            methodNames: ["sampleSelection"], expectedValue: "kick"
        ) == nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func metadataDecodingRevalidatesNestedBoundsAndBankSiteIdentity() throws {
        let bank = try EditorSemanticMetadata.SampleBank(sourceID: 0, displayName: "bank.wav", values: ["kick"])
        let site = try EditorSemanticMetadata.SampleCompletionSite(
            sourceID: 0, contentRange: NSRange(location: 0, length: 4), values: ["kick"]
        )
        let metadata = try EditorSemanticMetadata(revision: 45, sampleBanks: [bank], completionSites: [site])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoder = PropertyListDecoder()
        let roundTrip = try decoder.decode(EditorSemanticMetadata.self, from: encoder.encode(metadata))
        #expect(roundTrip == metadata)
        let empty = try EditorSemanticMetadata.SampleCompletionSite(
            sourceID: 0, contentRange: NSRange(location: 4, length: 0), values: ["kick"])
        #expect(try decoder.decode(EditorSemanticMetadata.SampleCompletionSite.self,
            from: encoder.encode(empty)) == empty)
        #expect(throws: (any Error).self) {
            try EditorSemanticMetadata.SampleCompletionSite(
                sourceID: 0, contentRange: NSRange(location: 4, length: -1), values: ["kick"])
        }

        let malformed: [String: Any] = [
            "revision": 45,
            "sampleBanks": [["sourceID": 0, "displayName": "bank.wav", "values": ["kick"]]],
            "completionSites": [["sourceID": 0, "contentRange": [0, 4], "values": ["snare"]]]
        ]
        let malformedData = try PropertyListSerialization.data(
            fromPropertyList: malformed, format: .binary, options: 0
        )
        #expect(throws: (any Error).self) {
            try decoder.decode(EditorSemanticMetadata.self, from: malformedData)
        }
        let mismatchedSite = try EditorSemanticMetadata.SampleCompletionSite(
            sourceID: 0, contentRange: NSRange(location: 0, length: 4), values: ["snare"]
        )
        #expect(throws: (any Error).self) {
            try EditorSemanticMetadata(revision: 45, sampleBanks: [bank], completionSites: [mismatchedSite])
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func diagnosticMapsCompilerUTF8OffsetToUnicodeDocumentRange() throws {
        let source = "// 🎵\nstruct Session: Music {\n  var body: some Sound {\n    Synthesizer(.sine).gain(\"1 nope\")\n  }\n}"
        let located = LocatedSoundCompilationError(
            underlying: .invalidGainPattern(.invalidToken(token: "nope", index: 1, offset: 2)),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 4, column: 33),
            utf8Offset: 2,
            patternText: "1 nope"
        )
        let diagnostic = try WorkerCompilerDiagnostic(revision: 9, error: located)
        let range = try #require(try ExpressionResultLocations.diagnosticRange(source: source, diagnostic: diagnostic))
        #expect((source as NSString).substring(with: range.utf16Range) == "nope")
        #expect(range.fileID == "Session.swift")
        #expect(range.line == 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func completionAnnotationsJoinOnlyExactSignatureKeys() throws {
        let key = SwiftCompletionSemanticKey(
            label: "gain(value: Double)",
            detail: "ModifiedSound",
            argumentIndex: 0
        )
        let annotation = try #require(SwiftCompletionSignatureTable.annotation(for: key))
        #expect(annotation.unit == "amplitude")
        #expect(annotation.minimum == 0)
        #expect(annotation.maximum == 2)
        let unknown = SwiftCompletionSemanticKey(
            label: "gain(pattern: GainPattern)", detail: "ModifiedSound", argumentIndex: 0
        )
        #expect(SwiftCompletionSignatureTable.annotation(for: unknown) == nil)
        #expect(SwiftCompletionSignatureTable.annotation(for: SwiftCompletionSemanticKey(
            label: "gain(value: Double)", detail: nil, argumentIndex: 0
        )) == nil)
        #expect(SwiftCompletionSignatureTable.annotation(for: SwiftCompletionSemanticKey(
            label: "gain(value: Double)", detail: "WrongDetail", argumentIndex: 0
        )) == nil)
    }

    @Test(.timeLimit(.minutes(3)))
    func diagnosticUsesAnchoredCallInsteadOfEarlierMatchingInitializerLiteral() throws {
        let source = "// 🎵\nstruct Session: Music {\n  var body: some Sound {\n    let p = \"1 nope\"; Synthesizer(.sine).gain(\"1 nope\")\n  }\n}"
        let located = LocatedSoundCompilationError(
            underlying: .invalidGainPattern(.invalidToken(token: "nope", index: 1, offset: 2)),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 4, column: 42),
            utf8Offset: 2,
            patternText: "1 nope"
        )
        let diagnostic = try WorkerCompilerDiagnostic(revision: 10, error: located)
        let range = try #require(try ExpressionResultLocations.diagnosticRange(source: source, diagnostic: diagnostic))
        #expect((source as NSString).substring(with: range.utf16Range) == "nope")
        #expect(range.utf16Range.location > (source as NSString).range(of: "let p").location)

        let variableDiagnostic = try WorkerCompilerDiagnostic(
            revision: 10,
            error: LocatedSoundCompilationError(
                underlying: .invalidGainPattern(.invalidToken(token: "nope", index: 1, offset: 2)),
                anchor: SoundSourceAnchor(fileID: "Session.swift", line: 4, column: 42),
                utf8Offset: 2,
                patternText: "1 nope"
            )
        )
        let variableSource = "struct Session: Music {\n  var body: some Sound {\n    let p = \"1 nope\"; Synthesizer(.sine).gain(p)\n  }\n}"
        #expect(try ExpressionResultLocations.diagnosticRange(
            source: variableSource, diagnostic: variableDiagnostic
        ) == nil)
        let foreignDiagnostic = try WorkerCompilerDiagnostic(
            revision: 10,
            error: LocatedSoundCompilationError(
                underlying: .invalidGainPattern(.invalidToken(token: "nope", index: 1, offset: 2)),
                anchor: SoundSourceAnchor(fileID: "Other.swift", line: 4, column: 42),
                utf8Offset: 2,
                patternText: "1 nope"
            )
        )
        #expect(try ExpressionResultLocations.diagnosticRange(
            source: source, diagnostic: foreignDiagnostic
        ) == nil)
    }
}
