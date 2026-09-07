import Testing
import SwiftMusic

struct DynamicsCompilationTests {
    private struct Routed<Content: Sound>: Music {
        let content: Content
        var body: some Sound {
            BusReturn("room").gain(0.5)
            content
        }
    }

    private func compressor(bus: String? = nil) throws -> SidechainCompressor {
        try SidechainCompressor(threshold: Decibels(value: -18), ratio: 4,
                                attack: .milliseconds(2), release: .milliseconds(50),
                                knee: Decibels(value: 6), sidechainBus: bus)
    }

    @Test(.timeLimit(.minutes(3)))
    func typedDescriptorsValidateUnitsAndPreserveLegacyCompressor() throws {
        let value = try compressor(bus: "room")
        #expect(value.attackSeconds == 0.002)
        #expect(value.releaseSeconds == 0.05)
        #expect(value.kneeDecibels == 6)
        #expect(value.sidechainBus == "room")
        #expect(throws: SoundParameterError.self) {
            try SidechainCompressor(threshold: Decibels(value: -12), ratio: 0.5,
                attack: .zero, release: .zero, knee: Decibels(value: 0))
        }
        #expect(throws: SoundParameterError.self) {
            try NoiseGate(threshold: Decibels(value: -40), attack: .seconds(-1), release: .zero)
        }
        #expect(throws: SoundParameterError.self) {
            try Limiter(ceiling: Decibels(value: 1), release: .zero)
        }
        #expect(throws: SoundParameterError.self) { try compressor(bus: " ") }
        let legacy = try SoundCompiler().compile(Synthesizer(.sine)
            .effect(.compressor(thresholdDecibels: -20, ratio: 2)))
        #expect(legacy.renderNodes.last == .effect(input: 0, effect: .compressor(thresholdDecibels: -20, ratio: 2)))
    }

    @Test(.timeLimit(.minutes(3)))
    func duckRulesSurviveGeneratorsAndFiniteLiveExpansion() throws {
        let depth = try Decibels(value: -12)
        let seed = Synthesizer(.sine).send(to: "room", level: 1)
        let before = seed.duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(50))
        let declarations = [
            before.notes("C4 D4"), before.rhythm("x ~ x ~"),
            seed.notes("C4 D4").duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(50)),
            seed.rhythm("x ~ x ~").duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(50))
        ]
        for declaration in declarations {
            let finite = try SoundCompiler().compile(Routed(content: declaration))
            let live = try SoundCompiler().compile(Routed(content: declaration),
                liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
            for result in [finite, live] {
                #expect(result.events.count == 2)
                #expect(result.eventDucks.map(\.triggerEventIndex) == [0, 1])
                #expect(result.eventDucks.allSatisfy { $0.targetBus == "room" && $0.depthDecibels == -12 })
            }
        }
        let repeated = try SoundCompiler().compile(Routed(content: before.repeated(3)))
        #expect(repeated.eventDucks.map(\.triggerEventIndex) == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(3)))
    func sortedEventsAndPostDuckSidechainKeepExactIdentity() throws {
        let depth = try Decibels(value: -9)
        struct Song: Music {
            let depth: Decibels
            let compressor: SidechainCompressor
            var body: some Sound {
                BusReturn("room").gain(0.5)
                Synthesizer(.sine).offset(.quarter)
                    .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(50))
                    .send(to: "room", level: 1)
                Synthesizer(.square).effect(.sidechainCompressor(compressor))
            }
        }
        let result = try SoundCompiler().compile(Song(depth: depth, compressor: compressor(bus: "room")))
        #expect(result.events[0].sourceID == 1)
        #expect(result.eventDucks.map(\.triggerEventIndex) == [1])
        let duckID = try #require(result.renderNodes.firstIndex { if case .eventDuck = $0 { true } else { false } })
        guard case .eventDuck(let returnID, let rules) = result.renderNodes[duckID] else { return }
        #expect(rules == [0])
        #expect(returnID < duckID)
        #expect(result.renderNodes.contains(.gain(input: duckID, value: 0.5)))
        let sidechainID = try #require(result.renderNodes.firstIndex { if case .sidechainEffect = $0 { true } else { false } })
        guard case .sidechainEffect(let input, let detector, let descriptor) = result.renderNodes[sidechainID] else { return }
        #expect(input < sidechainID && detector < sidechainID)
        #expect(detector == duckID)
        #expect(descriptor == (try compressor(bus: "room")))
    }

    @Test(.timeLimit(.minutes(3)))
    func missingSidechainCyclesAndInvalidDuckFailExplicitly() throws {
        let processor = try compressor(bus: "room")
        #expect(throws: SoundCompilationError.invalidBusRouting(.missingReturn("room"))) {
            try SoundCompiler().compile(Synthesizer(.sine).effect(.sidechainCompressor(processor)))
        }
        #expect(throws: SoundCompilationError.invalidBusRouting(.cycle)) {
            try SoundCompiler().compile(Routed(content: Synthesizer(.sine)
                .effect(.sidechainCompressor(processor)).send(to: "room", level: 1)))
        }
        let depth = try Decibels(value: -6)
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Synthesizer(.sine)
                .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .zero))
        }
        #expect(throws: SoundCompilationError.invalidBusRouting(.missingReturn("room"))) {
            try SoundCompiler().compile(Synthesizer(.sine)
                .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(10)))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func ruleAndDynamicsExpansionLimitsRejectExcess() throws {
        let depth = try Decibels(value: -6)
        let trigger = Synthesizer(.sine).send(to: "room", level: 1)
            .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(10))
        #expect(try SoundCompiler().compile(Routed(content: trigger.repeated(1_024))).eventDucks.count == 1_024)
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(Routed(content: trigger.repeated(1_025)))
        }
        var chain = Synthesizer(.sine).gain(1)
        for _ in 0..<32 { chain = chain.effect(.compressor(thresholdDecibels: -20, ratio: 2)) }
        #expect(try SoundCompiler().compile(chain).events.count == 1)
        #expect(throws: SoundCompilationError.self) {
            try SoundCompiler().compile(chain.effect(.compressor(thresholdDecibels: -20, ratio: 2)))
        }
    }
}
