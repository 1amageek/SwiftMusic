@testable import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct TrackMixRenderingTests {
    private func render<S: Sound>(_ sound: S) throws -> PreparedLoop {
        try LoopRenderer().render(SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func defaultTrackIsExactAndExplicitMixPreservesEvents() throws {
        let source = Synthesizer(.sine).notes("C4 E4")
        let track = Track("lead") { source }
        let plain = try render(source)
        let baseline = try render(track)
        #expect(plain.samples == baseline.samples)
        let mixed = try render(track.trackLevel(0.5).trackPan(-1))
        #expect(stride(from: 0, to: mixed.samples.count, by: 2).allSatisfy { index in
            abs(mixed.samples[index] - baseline.samples[index] * 0.5) < 0.000001
                && abs(mixed.samples[index + 1]) < 0.000001
        })
        #expect(mixed.events == baseline.events)
        let centered = try render(track.trackPan(0))
        #expect(centered.samples != baseline.samples)
        #expect(try render(track.trackPan(0).trackPan(nil)).samples == baseline.samples)
        let muted = try render(track.trackMuted())
        #expect(muted.samples.allSatisfy { $0 == 0 })
        #expect(muted.events == baseline.events)
    }

    @Test(.timeLimit(.minutes(3)))
    func siblingSoloAndAncestorMuteHaveDeterministicPrecedence() throws {
        let lead = Track("lead") { Synthesizer(.sine).notes("C4") }
        let bass = Track("bass") { Synthesizer(.square).notes("C2") }
        let selected = Track("all") {
            lead.trackSolo()
            bass
        }
        #expect(try render(selected).samples == render(lead).samples)
        #expect(try render(selected.trackMuted()).samples.allSatisfy { $0 == 0 })
        let all = Track("all") { lead; bass }.trackSolo()
        #expect(try render(all).samples == render(Track("all") { lead; bass }).samples)
        #expect(try render(Track("all") { lead.trackSolo().trackMuted(); bass }).samples.allSatisfy { $0 == 0 })
    }

    @Test(.timeLimit(.minutes(3)))
    func soloChildExcludesAncestorOwnedAndUntrackedSources() throws {
        struct Session: Sound {
            var body: some Sound {
                Track("outer") {
                    Synthesizer(.sine).notes("C4")
                    Track("inner") { Synthesizer(.sine).notes("E4") }.trackSolo()
                    Track("other") { Synthesizer(.sine).notes("G4") }
                }.trackLevel(0.5)
                Synthesizer(.square).notes("C2")
            }
        }
        let actual = try render(Session())
        let expected = try render(Track("inner") { Synthesizer(.sine).notes("E4") }.trackLevel(0.5))
        #expect(actual.samples == expected.samples)
        #expect(actual.events.count == 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func trackProcessingKeepsItsPositionAroundEffectsAndRetainsTail() throws {
        let source = Synthesizer(.sine).notes("C4").gain(4)
        let inside = Track("lead") { source.effect(.distortion(drive: 1)) }.trackLevel(0.5)
        let outside = Track("lead") { source }.trackLevel(0.5).effect(.distortion(drive: 1))
        let first = try render(inside)
        let second = try render(outside)
        #expect(zip(first.samples, second.samples).contains { abs($0 - $1) > 0.1 })
        let dry = Track("lead") { Synthesizer(.sine).notes("C4") }.trackLevel(0.5)
        let baseline = try render(dry)
        let delayed = try render(dry.effect(.delay(time: .quarter, feedback: 0, wet: 0.3)))
        #expect(delayed.beatCount > baseline.beatCount)
        #expect(delayed.events == baseline.events)
        #expect(delayed.samples.dropFirst(baseline.samples.count).contains { abs($0) > 0.0001 })
        #expect(throws: LoopRenderingError.self) { try render(dry.trackLevel(1e300)) }
    }

    @Test(.timeLimit(.minutes(3)))
    func inaudibleTrackCannotChokeTheSoloedVoice() throws {
        struct Session: Sound {
            let first: ModifiedSound
            let second: ModifiedSound
            var body: some Sound {
                Track("solo") { first }.trackSolo()
                Track("hidden") { second }
            }
        }
        let first = try Synthesizer(.sine).notes("C4").chokeGroup("shared")
        let second = try Synthesizer(.sine).notes("G4", cycle: .quarter).offset(.quarter).chokeGroup("shared")
        let session = Session(first: first, second: second)
        let reference = Track("solo") { first }.trackSolo()
        let finiteMatches = try render(session).samples == render(reference).samples
        #expect(finiteMatches)
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let actual = try LoopRenderer().render(SoundCompiler().compile(session, liveLoop: policy), bpm: 120, beatsPerBar: 4)
        let expected = try LoopRenderer().render(SoundCompiler().compile(reference, liveLoop: policy), bpm: 120, beatsPerBar: 4)
        let liveMatches = actual.samples == expected.samples
        #expect(liveMatches)
    }

    @Test(.timeLimit(.minutes(3)))
    func conflictingSourceOwnersFailInsteadOfMutingTheWholeSource() throws {
        var compiled = try SoundCompiler().compile(Track("lead") { Synthesizer(.sine).notes("C4 E4") })
        compiled.events[1].trackID = nil
        #expect(throws: LoopRenderingError.invalidSound("source has conflicting track owners")) {
            try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        }
        compiled.events[0].trackID = -1
        #expect(throws: LoopRenderingError.invalidSound("event track ID is invalid")) {
            try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func liveCompilationRetainsTrackBoundariesAndSourceClock() throws {
        let source = Track("lead") { Synthesizer(.sine).notes("C4 E4 G4").gain("1 0.5 0.25") }
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let compiler = SoundCompiler()
        let baseline = try compiler.compile(source, liveLoop: policy)
        let mixed = try compiler.compile(source.trackLevel(0.5).trackPan(-1), liveLoop: policy)
        #expect(mixed.events == baseline.events)
        let dry = try LoopRenderer().render(baseline, bpm: 120, beatsPerBar: 4)
        let wet = try LoopRenderer().render(mixed, bpm: 120, beatsPerBar: 4)
        #expect(wet.beatCount == dry.beatCount)
        #expect(stride(from: 0, to: wet.samples.count, by: 2).allSatisfy {
            abs(wet.samples[$0] - dry.samples[$0] * 0.5) < 0.000001 && abs(wet.samples[$0 + 1]) < 0.000001
        })
    }
}
