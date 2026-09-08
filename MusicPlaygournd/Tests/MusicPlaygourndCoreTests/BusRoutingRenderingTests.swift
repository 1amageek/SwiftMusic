import Testing
@testable import SwiftMusic
@testable import MusicPlaygourndCore

struct BusRoutingRenderingTests {
    private struct Routed<Source: Sound>: Sound {
        let source: Source
        var returnFirst = false
        var effect: AudioEffect? = nil
        var body: some Sound {
            if returnFirst { BusReturn("room") }
            source
            if !returnFirst {
                if let effect { BusReturn("room").effect(effect) }
                else { BusReturn("room") }
            }
        }
    }

    private func render<S: Sound>(_ sound: S, live: Bool = false) throws -> PreparedLoop {
        let compiler = SoundCompiler()
        let compiled = live
            ? try compiler.compile(sound, liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .beats(32)))
            : try compiler.compile(sound)
        return try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4)
    }

    @Test(.timeLimit(.minutes(3)))
    func sendsPreserveDrySignalAndSumInDeclaredOrder() throws {
        let source = Synthesizer(.sine).notes("C4").gain(0.2)
        let plain = try render(source)
        let sent = source.send(to: "room", level: 0.2).send(to: "room", level: 0.3)
        let result = try render(Routed(source: sent))
        let forward = try render(Routed(source: sent, returnFirst: true))
        #expect(result.events == plain.events)
        #expect(zip(result.samples, plain.samples).allSatisfy { abs($0 - $1 * 1.5) < 0.000001 })
        #expect(zip(result.samples, forward.samples).allSatisfy { abs($0 - $1) < 0.000001 })
        #expect(try render(Routed(source: source.send(to: "room", level: 0))).samples == plain.samples)
        #expect(try render(source.output("main")).samples == plain.samples)
        #expect(throws: LoopRenderingError.self) { try render(source.output("external")) }
        #expect(throws: LoopRenderingError.self) { try render(source.send(to: "missing", level: 1)) }
    }

    @Test(.timeLimit(.minutes(3)))
    func preAndPostSendsRespectFadersMuteAndSolo() throws {
        let source = Synthesizer(.sine).notes("C4").gain(0.2)
        let plain = try render(source)
        let lead = Track("lead") { source }.trackLevel(0.25).trackPan(-1)
        let pre = try render(Routed(source: lead.send(to: "room", level: 0.5, placement: .preFader)))
        let post = try render(Routed(source: lead.send(to: "room", level: 0.5, placement: .postFader)))
        let matches = stride(from: 0, to: plain.samples.count, by: 2).allSatisfy { frame in
            let preLeft = abs(pre.samples[frame] - plain.samples[frame] * 0.75) < 0.000001
            let preRight = abs(pre.samples[frame + 1] - plain.samples[frame + 1] * 0.5) < 0.000001
            let postLeft = abs(post.samples[frame] - plain.samples[frame] * 0.375) < 0.000001
            let postRight = abs(post.samples[frame + 1]) < 0.000001
            return preLeft && preRight && postLeft && postRight
        }
        #expect(matches)
        let live = try LoopRenderSession(sound: SoundCompiler().compile(
            Routed(source: lead.send(to: "room", level: 1, placement: .preFader))),
            bpm: 120, beatsPerBar: 4, revision: 1)
        let mute = LiveControlAddress(revision: 1, target: .track(0), parameter: .trackMute)
        #expect(live.baseline.samples.contains { $0 != 0 })
        #expect(try live.render(overrides: [.init(address: mute, value: .number(1))]).samples.allSatisfy { $0 == 0 })
        #expect(try live.render(overrides: [.init(address: mute, value: .number(0))]).samples == live.baseline.samples)
        #expect(try live.render().samples == live.baseline.samples)
        #expect(throws: LiveControlError.self) {
            try live.render(overrides: [.init(address: mute, value: .number(0.5))])
        }
        let muted = lead.trackMuted().send(to: "room", level: 1, placement: .preFader)
        #expect(try render(Routed(source: muted)).samples.allSatisfy { $0 == 0 })
        let parent = Track("parent") { lead.send(to: "room", level: 1, placement: .preFader) }.trackMuted()
        #expect(try render(Routed(source: parent)).samples.allSatisfy { $0 == 0 })
        let selected = lead.trackSolo().send(to: "room", level: 0.5, placement: .preFader)
        let both = Track("all") {
            selected
            Track("hidden") { Synthesizer(.square).notes("C2") }
                .send(to: "room", level: 1, placement: .postFader)
        }
        #expect(try render(Routed(source: both)).samples == render(Routed(source: selected)).samples)
    }

    @Test(.timeLimit(.minutes(3)))
    func busEffectsKeepFiniteTailsAndSeamlessWindows() throws {
        let source = Synthesizer(.sine).notes("C4 ~ ~ ~").send(to: "room", level: 0.5)
        let routed = Routed(source: source, effect: .delay(time: .whole, feedback: 0, wet: 1))
        let finite = try render(routed)
        let live = try render(routed, live: true)
        #expect(finite.beatCount == 8)
        #expect(finite.samples.dropFirst(176_400).contains { abs($0) > 0.01 })
        #expect(live.beatCount == 4)
        let plain = try render(Synthesizer(.sine).notes("C4 ~ ~ ~"), live: true)
        #expect(zip(live.samples, plain.samples).allSatisfy { abs($0 - $1 * 1.5) < 0.000001 })
    }

    @Test(.timeLimit(.minutes(3)))
    func bufferLivenessRejectsTheFirstExcessBeforeRendering() throws {
        struct Session: Sound {
            let count: Int
            var body: some Sound {
                for _ in 0..<count {
                    Synthesizer(.sine).notes("C4").send(to: "room", level: 0.01)
                }
                BusReturn("room")
            }
        }
        #expect(try render(Session(count: 31)).samples.contains { abs($0) > 0.01 })
        #expect(throws: LoopRenderingError.invalidSound("render graph exceeds 32 live stereo buffers")) {
            try render(Session(count: 32))
        }
        struct Plain: Sound {
            var body: some Sound {
                for _ in 0..<32 { Synthesizer(.sine).notes("C4") }
            }
        }
        #expect(try render(Plain()).samples.contains { abs($0) > 0.01 })
    }

    @Test(.timeLimit(.minutes(3)))
    func malformedReturnAndNonfiniteContributionFailExplicitly() throws {
        let source = Synthesizer(.sine).notes("C4").send(to: "room", level: 0.5)
        var compiled = try SoundCompiler().compile(Routed(source: source))
        let index = try #require(compiled.renderNodes.firstIndex { if case .busReturn = $0 { true } else { false } })
        if case .busReturn(let bus, let inputs) = compiled.renderNodes[index] {
            compiled.renderNodes[index] = .busReturn(bus: bus, inputs: inputs + inputs)
        }
        #expect(throws: LoopRenderingError.self) { try LoopRenderer().render(compiled, bpm: 120, beatsPerBar: 4) }
        #expect(throws: LoopRenderingError.self) {
            try render(Routed(source: Synthesizer(.sine).notes("C4").send(to: "room", level: 1e300)))
        }
    }
}
