import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct ModulationRenderingTests {
    private func impulse(_ count: Int) -> StereoBuffer {
        var buffer = StereoBuffer(frameCount: count)
        buffer.left[0] = 1; buffer.right[0] = 1
        return buffer
    }

    private func processFullBuffer(
        _ effect: AudioEffect,
        buffer: inout StereoBuffer,
        seamless: Bool
    ) throws {
        let horizon = buffer.left.count
        try ModulationProcessor.process(
            effect, buffer: &buffer, inputHorizon: horizon, seamless: seamless
        )
    }

    @Test(.timeLimit(.minutes(3)))
    func fractionalDelaysFeedbackAndOwnedTailsMatchReference() throws {
        var chorus = impulse(2_000)
        try processFullBuffer(.chorus(rateHz: 1, depth: 0, wet: 1), buffer: &chorus, seamless: false)
        #expect(abs(chorus.left[661] - 0.5) < 0.00001)
        #expect(abs(chorus.left[662] - 0.5) < 0.00001)
        #expect(chorus.left == chorus.right)
        #expect(try ModulationProcessor.tailFrames(.chorus(rateHz: 1, depth: 0, wet: 1)) == 662)
        var flanger = impulse(64)
        let feedback = AudioEffect.flanger(rateHz: 1, delaySeconds: 2 / 44_100,
                                           depthSeconds: 0, feedback: 0.5, wet: 1)
        try processFullBuffer(feedback, buffer: &flanger, seamless: false)
        #expect(flanger.left[2] == 1 && flanger.left[4] == 0.5 && flanger.left[6] == 0.25)
        #expect(try ModulationProcessor.tailFrames(feedback) == 34)
        let fractional = AudioEffect.flanger(rateHz: 1, delaySeconds: 1.5 / 44_100,
                                             depthSeconds: 0, feedback: 0.0001, wet: 1)
        #expect(try ModulationProcessor.tailFrames(fractional) == 4)
        var fractionalBuffer = impulse(8)
        try processFullBuffer(fractional, buffer: &fractionalBuffer, seamless: false)
        #expect(fractionalBuffer.left[4] > 0.000024)
        #expect(throws: (any Error).self) {
            try ModulationProcessor.tailFrames(.flanger(rateHz: 1, delaySeconds: 0.5 / 44_100,
                                                        depthSeconds: 0, feedback: 0, wet: 1))
        }
        #expect(throws: (any Error).self) {
            try ModulationProcessor.tailFrames(.flanger(rateHz: 1, delaySeconds: 1,
                                                        depthSeconds: 0, feedback: 0.99, wet: 1))
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func finiteModulationStopsAtInputHorizonAndDeclaredFlangerTail() throws {
        var phaser = impulse(32)
        try EffectProcessor.apply(
            .phaser(rateHz: 2, minimumHz: 100, maximumHz: 1_000,
                    stages: 2, feedback: 0.25, wet: 1),
            to: &phaser,
            inputHorizon: 1,
            bpm: 120,
            seamless: false,
            node: 1,
            convolver: nil
        )
        #expect(phaser.left.dropFirst().allSatisfy { $0 == 0 })
        #expect(phaser.right.dropFirst().allSatisfy { $0 == 0 })

        let flanger = AudioEffect.flanger(
            rateHz: 1, delaySeconds: 2 / 44_100,
            depthSeconds: 0, feedback: 0.5, wet: 1
        )
        var buffer = impulse(40)
        try EffectProcessor.apply(
            flanger,
            to: &buffer,
            inputHorizon: 1,
            bpm: 120,
            seamless: false,
            node: 1,
            convolver: nil
        )
        #expect(abs(buffer.left[34]) > 0.00001)
        #expect(buffer.left.dropFirst(35).allSatisfy { $0 == 0 })
        try EffectProcessor.apply(
            .saturation(drive: 0.5),
            to: &buffer,
            inputHorizon: 35,
            bpm: 120,
            seamless: false,
            node: 1,
            convolver: nil
        )
        #expect(buffer.left.dropFirst(35).allSatisfy { $0 == 0 })
        #expect(buffer.right.dropFirst(35).allSatisfy { $0 == 0 })
    }

    @Test(.timeLimit(.minutes(3)))
    func phaserMatchesIndependentDifferenceEquation() throws {
        var buffer = impulse(128)
        let effect = AudioEffect.phaser(rateHz: 2, minimumHz: 100, maximumHz: 1_000,
                                       stages: 2, feedback: 0.25, wet: 0.6)
        try processFullBuffer(effect, buffer: &buffer, seamless: false)
        var previousInput = [0.0, 0.0], previousOutput = [0.0, 0.0]
        var feedback = 0.0
        var error = 0.0
        for frame in buffer.left.indices {
            let input = frame == 0 ? 1.0 : 0.0
            let frequency = 100 + 900 * (1 + sin(2 * Double.pi * Double(frame) * 2 / 44_100)) / 2
            let tangent = tan(Double.pi * frequency / 44_100)
            let coefficient = (tangent - 1) / (tangent + 1)
            var value = input + 0.25 * feedback
            for stage in 0..<2 {
                let output = coefficient * value + previousInput[stage] - coefficient * previousOutput[stage]
                previousInput[stage] = value; previousOutput[stage] = output; value = output
            }
            feedback = value
            error = max(error, abs(Double(buffer.left[frame]) - (input * 0.4 + value * 0.6)))
        }
        #expect(error < 0.000001)
    }

    @Test(.timeLimit(.minutes(3)))
    func neutralBranchesWidthAndStereoChorusAreExact() throws {
        var original = impulse(4_410)
        original.left[1] = 0.25; original.right[1] = -0.25
        let neutral: [AudioEffect] = [
            .chorus(rateHz: 3, depth: 1, wet: 0),
            .flanger(rateHz: 3, delaySeconds: 0.01, depthSeconds: 0.001, feedback: 0.2, wet: 0),
            .phaser(rateHz: 3, minimumHz: 100, maximumHz: 2_000, stages: 4, feedback: 0.2, wet: 0),
            .stereoWidth(1)
        ]
        for effect in neutral {
            var copy = original
            try processFullBuffer(effect, buffer: &copy, seamless: true)
            #expect(copy.left == original.left && copy.right == original.right)
        }
        var mono = original
        try processFullBuffer(.stereoWidth(0), buffer: &mono, seamless: false)
        #expect(mono.left[0] == 1 && mono.right[0] == 1)
        #expect(mono.left[1] == 0 && mono.right[1] == 0)
        var wide = original
        try processFullBuffer(.stereoWidth(2), buffer: &wide, seamless: false)
        #expect(wide.left[1] == 0.5 && wide.right[1] == -0.5)
        var chorus = original
        try processFullBuffer(.chorus(rateHz: 10, depth: 1, wet: 1), buffer: &chorus, seamless: true)
        #expect(chorus.left != chorus.right)
        var monoBefore = original
        try processFullBuffer(.stereoWidth(0), buffer: &monoBefore, seamless: true)
        try processFullBuffer(.chorus(rateHz: 10, depth: 1, wet: 1), buffer: &monoBefore, seamless: true)
        try processFullBuffer(.stereoWidth(0), buffer: &chorus, seamless: true)
        #expect(chorus.left == chorus.right)
        #expect(monoBefore.left != monoBefore.right)
    }

    @Test(.timeLimit(.minutes(3)))
    func modulationHasVerifiedPeriodicStateOrTypedFailure() throws {
        var input = StereoBuffer(frameCount: 4_410)
        for index in input.left.indices {
            input.left[index] = Float(sin(2 * Double.pi * 100 * Double(index) / 44_100)) * 0.2
            input.right[index] = input.left[index]
        }
        let effects: [AudioEffect] = [
            .chorus(rateHz: 10, depth: 0.8, wet: 0.5),
            .flanger(rateHz: 10, delaySeconds: 0.002, depthSeconds: 0.001, feedback: 0.3, wet: 0.5),
            .phaser(rateHz: 10, minimumHz: 100, maximumHz: 2_000, stages: 4, feedback: 0.2, wet: 0.5)
        ]
        for effect in effects {
            var one = input
            var two = StereoBuffer(frameCount: 8_820)
            two.left = input.left + input.left; two.right = input.right + input.right
            try processFullBuffer(effect, buffer: &one, seamless: true)
            try processFullBuffer(effect, buffer: &two, seamless: true)
            var difference: Float = 0
            for index in one.left.indices {
                difference = max(difference, abs(one.left[index] - two.left[index]),
                                 abs(one.left[index] - two.left[index + one.left.count]))
            }
            #expect(difference < 0.000001)
            #expect(one.left != input.left)
        }
        #expect(throws: LoopRenderingError.nonPeriodicModulationState) {
            var buffer = input
            try processFullBuffer(.chorus(rateHz: 3, depth: 0.5, wet: 1), buffer: &buffer, seamless: true)
        }
        #expect(throws: LoopRenderingError.nonPeriodicModulationState) {
            var buffer = StereoBuffer(frameCount: 4_410, repeating: 1)
            try processFullBuffer(.phaser(rateHz: 10, minimumHz: 100, maximumHz: 200,
                stages: 2, feedback: 0.99999, wet: 1), buffer: &buffer, seamless: true)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func postMixFiltersAndModulationAliasesReachRealPCM() throws {
        let compiler = SoundCompiler()
        let base = Synthesizer(.sine).notes("A4").gate(1)
        let plain = try LoopRenderer().render(compiler.compile(base), bpm: 120, beatsPerBar: 4)
        func energy(_ loop: PreparedLoop) -> Double {
            loop.samples.reduce(0) { $0 + Double($1) * Double($1) }
        }
        let low = try LoopRenderer().render(compiler.compile(base.effect(.filter(kind: .lowPass, cutoffHz: 50, resonance: 0))), bpm: 120, beatsPerBar: 4)
        let high = try LoopRenderer().render(compiler.compile(base.effect(.filter(kind: .highPass, cutoffHz: 5_000, resonance: 0))), bpm: 120, beatsPerBar: 4)
        let notch = try LoopRenderer().render(compiler.compile(base.effect(.filter(kind: .notch, cutoffHz: 440, resonance: 1))), bpm: 120, beatsPerBar: 4)
        #expect(energy(low) < energy(plain) * 0.01)
        #expect(energy(high) < energy(plain) * 0.01)
        #expect(energy(notch) < energy(plain) * 0.01)
        let band = try LoopRenderer().render(compiler.compile(base.effect(.filter(kind: .bandPass, cutoffHz: 440, resonance: 1))), bpm: 120, beatsPerBar: 4)
        #expect(energy(band) > energy(plain) * 0.95)
        let policy = try LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)
        let filteredLive = try LoopRenderer().render(compiler.compile(base.effect(.filter(kind: .lowPass, cutoffHz: 1_000, resonance: 0.5)), liveLoop: policy), bpm: 120, beatsPerBar: 4)
        #expect(filteredLive.samples.contains { abs($0) > 0.01 })
        let modulated = base.tremolo(rate: .synchronized(period: .whole), depth: 0.5)
            .vibrato(rate: .synchronized(period: .whole), depth: try Semitones(value: 1))
        let loop = try LoopRenderer().render(compiler.compile(modulated,
            liveLoop: LiveLoopPolicy(beatsPerBar: 4, maximumBeats: .whole)), bpm: 120, beatsPerBar: 4)
        #expect(loop.samples.contains { abs($0) > 0.01 })
        #expect(loop.samples != plain.samples)
        let neutral = try LoopRenderer().render(compiler.compile(base
            .tremolo(rate: .synchronized(period: .whole), depth: 0)
            .vibrato(rate: .synchronized(period: .whole), depth: Semitones(value: 0))), bpm: 120, beatsPerBar: 4)
        #expect(neutral.samples == plain.samples)
    }
}
