import Testing
@testable import SwiftMusic

struct DeclarationModifierTests {
    @Test(.timeLimit(.minutes(1)))
    func declarationsMatchValidatedValuesInFiniteAndLiveCompilation() throws {
        let source = Synthesizer(.saw).notes("C2 Eb2 G2 Bb2")
        let envelope = try Envelope(attack: .milliseconds(2), decay: .milliseconds(95),
            sustainLevel: 0.35, release: .milliseconds(30))
        let eager = source.envelope(envelope)
            .filterEnvelope(envelope, depth: try Semitones(value: 24))
            .pitchEnvelope(envelope, depth: try Semitones(value: 12))
            .unison(try Unison(voices: 3, detuneCents: 20))
        let declared = source
            .envelope(attack: .milliseconds(2), decay: .milliseconds(95), sustainLevel: 0.35, release: .milliseconds(30))
            .filterEnvelope(attack: .milliseconds(2), decay: .milliseconds(95), sustainLevel: 0.35, release: .milliseconds(30), depth: 24)
            .pitchEnvelope(attack: .milliseconds(2), decay: .milliseconds(95), sustainLevel: 0.35, release: .milliseconds(30), depth: 12)
            .unison(voices: 3, detuneCents: 20)
        let compiler = SoundCompiler()
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        for live in [false, true] {
            let a = try live ? compiler.compile(eager, liveLoop: policy) : compiler.compile(eager)
            let b = try live ? compiler.compile(declared, liveLoop: policy) : compiler.compile(declared)
            #expect(a.sources == b.sources)
            #expect(a.events == b.events)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidDeclarationsFailAtTheirCallSiteWithoutThrowingFromBody() throws {
        let source = Synthesizer(.saw).notes("C2")
        let invalid = [
            source.envelope(attack: .milliseconds(-1), decay: .zero, sustainLevel: 1, release: .zero, fileID: "Session.swift", line: 12),
            source.filterEnvelope(attack: .zero, decay: .zero, sustainLevel: 1, release: .zero, depth: .infinity, fileID: "Session.swift", line: 12),
            source.pitchEnvelope(attack: .zero, decay: .zero, sustainLevel: 2, release: .zero, depth: 12, fileID: "Session.swift", line: 12),
            source.unison(voices: 0, detuneCents: 20, fileID: "Session.swift", line: 12),
            source.duck(targetBus: "music", depth: .nan, attack: .zero, recovery: .milliseconds(100), fileID: "Session.swift", line: 12)
        ]
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        for sound in invalid {
            #expect {
                try SoundCompiler().compileDetailed(sound, liveLoop: policy)
            } throws: { error in
                guard let located = error as? LocatedSoundCompilationError else { return false }
                guard case .invalidParameter = located.underlying else { return false }
                return located.anchor.fileID == "Session.swift" && located.anchor.line == 12
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func duckDeclarationsRetainExpandedTriggers() throws {
        struct Routed: Sound {
            let trigger: ModifiedSound
            var body: some Sound {
                trigger.send(to: "music", level: 1)
                BusReturn("music")
            }
        }
        let source = Sample("kick").rhythm("x*4")
        let eager = source.duck(targetBus: "music", depth: try Decibels(value: -14), attack: .milliseconds(200), recovery: .milliseconds(230))
        let declared = source.duck(targetBus: "music", depth: -14, attack: .milliseconds(200), recovery: .milliseconds(230))
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let a = try SoundCompiler().compile(Routed(trigger: eager), liveLoop: policy)
        let b = try SoundCompiler().compile(Routed(trigger: declared), liveLoop: policy)
        #expect(a.eventDucks == b.eventDucks)
        #expect(b.eventDucks.count == 4)
    }
}
