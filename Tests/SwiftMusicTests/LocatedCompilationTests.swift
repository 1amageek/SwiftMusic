import Foundation
import Testing
@testable import SwiftMusic

struct LocatedCompilationTests {
    private func assertLocated<S: Sound>(
        _ sound: S,
        anchor: SoundSourceAnchor,
        offset: Int?
    ) throws {
        do {
            _ = try SoundCompiler().compileDetailed(sound)
            Issue.record("Expected a located compilation failure.")
        } catch let error as LocatedSoundCompilationError {
            #expect(error.anchor == anchor)
            #expect(error.utf8Offset == offset)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func detailedCompilationRetainsPatternAnchorAndTokenOffset() throws {
        let pattern: GainPattern = "1 nope"
        let sound = Synthesizer(.sine).gain(
            pattern,
            fileID: "Session.swift",
            line: 12,
            column: 8
        )

        #expect {
            try SoundCompiler().compileDetailed(sound)
        } throws: { error in
            guard let located = error as? LocatedSoundCompilationError else { return false }
            guard located.anchor == SoundSourceAnchor(fileID: "Session.swift", line: 12, column: 8),
                  located.utf8Offset == 2 else { return false }
            return located.underlying == .invalidGainPattern(
                .invalidToken(token: "nope", index: 1, offset: 2)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ordinaryCompilationKeepsExistingErrorSurface() throws {
        let pattern: GainPattern = "1 nope"
        #expect {
            try SoundCompiler().compile(Synthesizer(.sine).gain(pattern))
        } throws: { error in
            error as? SoundCompilationError == .invalidGainPattern(
                .invalidToken(token: "nope", index: 1, offset: 2)
            )
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func detailedLiveCompilationRetainsLocatedFailure() throws {
        let pattern: PanPattern = "0 bad"
        let policy = try LiveLoopPolicy(
            beatsPerBar: 4,
            maximumBeats: MusicalTime(numerator: 4, denominator: 1)
        )
        #expect {
            try SoundCompiler().compileDetailed(
                Synthesizer(.sine).pan(
                    pattern,
                    fileID: "Session.swift",
                    line: 22,
                    column: 4
                ),
                liveLoop: policy
            )
        } throws: { error in
            guard let located = error as? LocatedSoundCompilationError else { return false }
            return located.anchor.line == 22 && located.utf8Offset == 2
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func everyPatternDomainRetainsItsDeclarationAnchorAndUTF8Offset() throws {
        try assertLocated(
            Synthesizer(.sine).rhythm(
                RhythmPattern(stringLiteral: "x nope"), fileID: "Session.swift", line: 31, column: 4
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 31, column: 4), offset: 2
        )
        try assertLocated(
            Synthesizer(.sine).notes(
                NotePattern(stringLiteral: "C4 nope"), fileID: "Session.swift", line: 32, column: 5
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 32, column: 5), offset: 3
        )
        try assertLocated(
            Synthesizer(.sine).gain(
                GainPattern(stringLiteral: "1 nope"), fileID: "Session.swift", line: 33, column: 6
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 33, column: 6), offset: 2
        )
        try assertLocated(
            Synthesizer(.sine).pan(
                PanPattern(stringLiteral: "0 nope"), fileID: "Session.swift", line: 34, column: 7
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 34, column: 7), offset: 2
        )
        try assertLocated(
            Synthesizer(.sine).transpose(
                PitchPattern(stringLiteral: "0 nope"), fileID: "Session.swift", line: 35, column: 8
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 35, column: 8), offset: 2
        )
        try assertLocated(
            Synthesizer(.sine).lowPass(
                CutoffPattern(stringLiteral: "400 nope"), fileID: "Session.swift", line: 36, column: 9
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 36, column: 9), offset: 4
        )
        let envelope = try Envelope(
            attackSeconds: 0.01, decaySeconds: 0.1, sustainLevel: 0.5, releaseSeconds: 0.1
        )
        try assertLocated(
            Synthesizer(.sine).envelope(
                try EnvelopePattern("tight", values: ["tight": envelope]).fast(0),
                fileID: "Session.swift", line: 37, column: 10
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 37, column: 10), offset: nil
        )
        let bank = try SampleBank([SampleAsset(
            key: "kick", fileURL: URL(fileURLWithPath: "/tmp/kick.caf")
        )])
        try assertLocated(
            Sample(bank: bank).sampleSelection(
                SampleSelectionPattern(stringLiteral: "kick nope"),
                fileID: "Session.swift", line: 38, column: 11
            ),
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 38, column: 11), offset: 5
        )
    }

    @Test(.timeLimit(.minutes(3)))
    func detailedCompilationPreservesLegacySuccessfulResult() throws {
        let sound = Synthesizer(.sine)
            .rhythm("x x")
            .notes("C4 C4")
            .gain("1 0.5")
            .pan("-1 1")
        let compiler = SoundCompiler()
        #expect(try compiler.compile(sound) == compiler.compileDetailed(sound))
    }
}
