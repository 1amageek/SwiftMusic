import Foundation
import Testing
import SwiftMusic
@testable import MusicPlaygourndCore

@MainActor
struct DynamicsRenderingTests {
    private func compressor(attack: Duration = .zero, release: Duration = .zero,
                            knee: Double = 0, bus: String? = nil) throws -> SidechainCompressor {
        try SidechainCompressor(threshold: Decibels(value: -20), ratio: 2,
                                attack: attack, release: release,
                                knee: Decibels(value: knee), sidechainBus: bus)
    }

    @Test(.timeLimit(.minutes(3)))
    func compressorTransferKneeAndStereoLinkMatchReference() throws {
        var input = StereoBuffer(frameCount: 1)
        input.left[0] = 1; input.right[0] = 0.5
        try DynamicsProcessor(.compressor(thresholdDecibels: -20, ratio: 2)).process(&input, seamless: false)
        #expect(abs(Double(input.left[0]) - pow(10, -10.0 / 20)) < 1e-7)
        #expect(input.right[0] == input.left[0] * 0.5)
        var knee = StereoBuffer(frameCount: 1, repeating: 0.1)
        try DynamicsProcessor(.sidechainCompressor(compressor(knee: 8))).process(&knee, seamless: false)
        #expect(abs(Double(knee.left[0]) - 0.1 * pow(10, -0.5 / 20)) < 1e-7)
        var neutral = StereoBuffer(frameCount: 4, repeating: 0.5)
        try DynamicsProcessor(.compressor(thresholdDecibels: -100, ratio: 1)).process(&neutral, seamless: false)
        #expect(neutral.left == [0.5, 0.5, 0.5, 0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func detectorAttackReleaseAndExternalInputHaveExactTrajectories() throws {
        let rate = PreparedLoop.requiredSampleRate
        var input = StereoBuffer(frameCount: 3, repeating: 0.5)
        var detector = StereoBuffer(frameCount: 3)
        detector.left = [1, 1, 0]
        let processor = try DynamicsProcessor(.sidechainCompressor(compressor(
            attack: .milliseconds(1), release: .milliseconds(2), bus: "key")))
        let result = try processor.process(&input, sidechain: detector, seamless: false)
        let attack = exp(-1 / (0.001 * rate))
        let release = exp(-1 / (0.002 * rate))
        #expect(abs(result.final - (1 - attack * attack) * release) < 1e-12)
        #expect(detector.left == [1, 1, 0])
        #expect(input.left == input.right)
        var loud = StereoBuffer(frameCount: 1, repeating: 0.5)
        let silent = StereoBuffer(frameCount: 1)
        try DynamicsProcessor(.sidechainCompressor(compressor(bus: "key")))
            .process(&loud, sidechain: silent, seamless: false)
        #expect(loud.left == [0.5])
    }

    @Test(.timeLimit(.minutes(3)))
    func gateOpensClosesAndLimiterEnforcesRepresentableCeiling() throws {
        let gate = try NoiseGate(threshold: Decibels(value: -20), attack: .zero, release: .milliseconds(1))
        var input = StereoBuffer(frameCount: 3)
        input.left = [0.5, 0.01, 0.01]; input.right = input.left
        let result = try DynamicsProcessor(.noiseGate(gate)).process(&input, seamless: false)
        let coefficient = exp(-1 / (0.001 * PreparedLoop.requiredSampleRate))
        #expect(input.left[0] == 0.5)
        #expect(abs(Double(input.left[1]) - 0.01 * coefficient) < 1e-8)
        #expect(abs(result.final - coefficient * coefficient) < 1e-12)
        let limiter = try Limiter(ceiling: Decibels(value: -6), release: .milliseconds(10))
        var peaks = StereoBuffer(frameCount: 3)
        peaks.left = [2, -2, 0.1]; peaks.right = [1, -1, 0.05]
        try DynamicsProcessor(.limiter(limiter)).process(&peaks, seamless: false)
        let ceiling = pow(10, -6.0 / 20)
        #expect(peaks.left.allSatisfy { abs(Double($0)) <= ceiling })
        #expect(peaks.left[2] > 0.025 && peaks.left[2] < 0.1)
        #expect(abs(peaks.right[0] / peaks.left[0] - 0.5) < 1e-7)
    }

    @Test(.timeLimit(.minutes(3)))
    func circularStateIsVerifiedAndUnresolvablePrecisionFails() throws {
        let processor = try DynamicsProcessor(.sidechainCompressor(compressor(
            attack: .milliseconds(1), release: .milliseconds(2))))
        var loop = StereoBuffer(frameCount: 128)
        loop.left = (0..<128).map { $0 < 32 ? 0.8 : 0.02 }; loop.right = loop.left
        var repeatLoop = loop
        let first = try processor.process(&loop, seamless: true)
        let second = try processor.process(&repeatLoop, seamless: true)
        #expect(abs(first.initial - first.final) <= 1e-12)
        #expect(first.initial == second.initial)
        #expect(loop.left == repeatLoop.left)
        let slow = try DynamicsProcessor(.sidechainCompressor(compressor(
            attack: .seconds(Int64.max), release: .seconds(Int64.max))))
        #expect(throws: LoopRenderingError.nonPeriodicDynamicsState) {
            try slow.process(&repeatLoop, seamless: true)
        }
        var invalid = StereoBuffer(frameCount: 1, repeating: .infinity)
        #expect(throws: LoopRenderingError.self) { try processor.process(&invalid, seamless: false) }
    }

    @Test(.timeLimit(.minutes(3)))
    func duckAttackRecoveryOverlapAndWrapMatchGainEnvelope() throws {
        struct Song: Music {
            let depth: Decibels
            let attack: Duration
            let recovery: Duration
            let offset: MusicalTime
            var body: some Sound {
                Synthesizer(.sine).offset(offset).send(to: "room", level: 1)
                    .duck(targetBus: "room", depth: depth, attack: attack, recovery: recovery)
                    .duck(targetBus: "room", depth: depth, attack: attack, recovery: recovery)
                BusReturn("room")
            }
        }
        let depth = try Decibels(value: -12)
        let compiled = try SoundCompiler().compile(Song(depth: depth, attack: .milliseconds(10),
            recovery: .milliseconds(20), offset: .zero))
        var input = StereoBuffer(frameCount: 2_000, repeating: 1)
        try DynamicsProcessor.duck(&input, rules: Array(compiled.eventDucks.indices), sound: compiled,
                                   secondsPerBeat: 0.5, seamless: false)
        let minimum = pow(10, -12.0 / 20)
        #expect(input.left[0] == 1)
        #expect(abs(Double(input.left[441]) - minimum) < 1e-7)
        #expect(abs(Double(input.left[882]) - (minimum + 1) / 2) < 1e-7)
        #expect(input.left[1_323] == 1)
        #expect(input.left == input.right)
        let wrapped = try SoundCompiler().compile(Song(depth: depth, attack: .zero,
            recovery: .seconds(1), offset: .quarter))
        var circular = StereoBuffer(frameCount: 44_100, repeating: 1)
        try DynamicsProcessor.duck(&circular, rules: Array(wrapped.eventDucks.indices), sound: wrapped,
                                   secondsPerBeat: 0.5, seamless: true)
        #expect(abs(Double(circular.left[22_050]) - minimum) < 1e-7)
        #expect(abs(Double(circular.left[0]) - (minimum + 1) / 2) < 1e-7)
        var short = StereoBuffer(frameCount: 22_050, repeating: 1)
        #expect(throws: LoopRenderingError.self) {
            try DynamicsProcessor.duck(&short, rules: Array(wrapped.eventDucks.indices), sound: wrapped,
                                       secondsPerBeat: 0.5, seamless: true)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func routedDynamicsAndEventDuckPreserveDryAndProvenance() throws {
        struct Song: Music {
            let depth: Decibels
            let compressor: SidechainCompressor
            var body: some Sound {
                Synthesizer(.sine).notes("C4 ~ ~ ~").gain(0.1)
                    .send(to: "music", level: 1)
                    .duck(targetBus: "music", depth: depth, attack: .zero, recovery: .milliseconds(100))
                BusReturn("music").effect(.sidechainCompressor(compressor))
                Synthesizer(.sine).notes("C2").gain(0.1).send(to: "key", level: 1)
                BusReturn("key").gain(0)
            }
        }
        struct Ducked: Music {
            let depth: Decibels
            var body: some Sound {
                Synthesizer(.sine).notes("C4 ~ ~ ~").gain(0.1)
                    .send(to: "room", level: 1)
                    .duck(targetBus: "room", depth: depth, attack: .zero, recovery: .milliseconds(100))
                BusReturn("room")
            }
        }
        let compiler = SoundCompiler()
        let plain = try LoopRenderer().render(compiler.compile(
            Synthesizer(.sine).notes("C4 ~ ~ ~").gain(0.1)), bpm: 120, beatsPerBar: 4)
        let ducked = try LoopRenderer().render(compiler.compile(Ducked(depth: Decibels(value: -12))),
                                              bpm: 120, beatsPerBar: 4)
        for frame in [441, 2_205, 4_410, 8_820] {
            let minimum = pow(10, -12.0 / 20)
            let gain = minimum + (1 - minimum) * min(1, Double(frame) / 4_410)
            let expected = Double(plain.samples[frame * 2]) * (1 + gain)
            #expect(abs(Double(ducked.samples[frame * 2]) - expected) < 1e-7)
        }
        #expect(ducked.events == plain.events)
        let song = Song(depth: try Decibels(value: -12), compressor: try compressor(bus: "key"))
        let compiled = try compiler.compile(song)
        let renderer = LoopRenderer()
        let result = try renderer.render(compiled, bpm: 120, beatsPerBar: 4)
        #expect(result.beatCount == 4)
        #expect(result.events.count == compiled.events.count)
        #expect(result.samples.contains { abs($0) > 0.01 })
        let live = try compiler.compile(song, liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole))
        #expect(try renderer.render(live, bpm: 120, beatsPerBar: 4).beatCount == 4)
    }
}
