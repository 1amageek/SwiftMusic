import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct EffectRenderingTests {
    private let sampleRate = PreparedLoop.requiredSampleRate

    @Test(.timeLimit(.minutes(3)))
    func shapersMatchTheirFormulasPreserveBypassAndRespectOrder() throws {
        let input: [Float] = [-1, -0.5, 0.25, 1]
        var saturation = StereoBuffer(frameCount: input.count)
        saturation.left = input
        saturation.right = input
        try EffectProcessor.apply(
            .saturation(drive: 0.5), to: &saturation, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 0, convolver: nil
        )
        let saturationExpected = input.map { value in
            let x = Double(value)
            return Float(x * 1.5 / (1 + 0.5 * abs(x)))
        }
        #expect(approximatelyEqual(saturation.left, saturationExpected))
        #expect(saturation.left == saturation.right)

        var bypass = StereoBuffer(frameCount: input.count)
        bypass.left = input
        bypass.right = input
        try EffectProcessor.apply(
            .saturation(drive: 0), to: &bypass, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 0, convolver: nil
        )
        #expect(bypass.left == input)
        #expect(bypass.right == input)

        var ordered = StereoBuffer(frameCount: input.count)
        ordered.left = input
        ordered.right = input
        try EffectProcessor.apply(
            .saturation(drive: 0.5), to: &ordered, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 0, convolver: nil
        )
        try EffectProcessor.apply(
            .distortion(drive: 0.5), to: &ordered, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 1, convolver: nil
        )

        var reversed = StereoBuffer(frameCount: input.count)
        reversed.left = input
        reversed.right = input
        try EffectProcessor.apply(
            .distortion(drive: 0.5), to: &reversed, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 0, convolver: nil
        )
        try EffectProcessor.apply(
            .saturation(drive: 0.5), to: &reversed, inputHorizon: input.count,
            bpm: 120, seamless: false, node: 1, convolver: nil
        )
        #expect(!approximatelyEqual(ordered.left, reversed.left))
    }

    @Test(.timeLimit(.minutes(3)))
    func delayUsesAbsoluteOffsetsAtMultipleTemposAndCircularFolding() throws {
        let feedback = 0.5
        let effect = AudioEffect.delay(time: .quarter, feedback: feedback, wet: 1)
        for bpm in [120.0, 137.0, 180.0] {
            let tail = try EffectProcessor.tailFrames(effect, bpm: bpm, node: 0)
            var buffer = StereoBuffer(frameCount: tail + 1)
            buffer.left[0] = 1
            buffer.right[0] = 1
            let convolver = try FFTConvolver(maximumLinearFrameCount: buffer.left.count + tail)
            try EffectProcessor.apply(
                effect, to: &buffer, inputHorizon: 1,
                bpm: bpm, seamless: false, node: 0, convolver: convolver
            )

            let delayFrames = Int((1 * 60 / bpm * sampleRate).rounded())
            let secondDelayFrames = Int((2 * 60 / bpm * sampleRate).rounded())
            #expect(abs(buffer.left[delayFrames] - 1) < 0.0001)
            #expect(abs(buffer.left[secondDelayFrames] - Float(feedback)) < 0.0001)
            #expect(abs(buffer.left[0]) < 0.000001)
            #expect(buffer.left == buffer.right)
        }

        let shortDelay = try MusicalTime(numerator: 1, denominator: 2_000)
        let circularEffect = AudioEffect.delay(time: shortDelay, feedback: 0, wet: 1)
        var circular = StereoBuffer(frameCount: 4)
        circular.left[0] = 1
        circular.right[0] = 1
        let circularOffset = Int((1.0 / 2_000 * 60 / 120 * sampleRate).rounded())
        let circularConvolver = try FFTConvolver(maximumLinearFrameCount: circular.left.count + circularOffset)
        try EffectProcessor.apply(
            circularEffect, to: &circular, inputHorizon: 1,
            bpm: 120, seamless: true, node: 0, convolver: circularConvolver
        )
        let foldedOffset = circularOffset % circular.left.count
        #expect(abs(circular.left[foldedOffset] - 1) < 0.0001)
        #expect(circular.left.enumerated().allSatisfy { index, value in
            index == foldedOffset ? abs(value - 1) < 0.0001 : abs(value) < 0.0001
        })
    }

    @Test(.timeLimit(.minutes(3)))
    func delayRejectsAQualifyingTailPastTheFiniteBound() throws {
        let effect = AudioEffect.delay(time: .whole, feedback: 0.99999, wet: 1)
        let sound = try SoundCompiler().compile(Synthesizer(.sine).notes("C4").effect(effect))
        #expect(throws: LoopRenderingError.invalidSound("delay tail exceeds 16 seconds")) {
            try LoopRenderer().render(sound, bpm: 40, beatsPerBar: 4)
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func equalizerMatchesIndependentRecurrenceAndPeriodicState() throws {
        let frequency = 1_000.0
        let gain = 6.0
        let q = 0.7
        let impulse = [Float](arrayLiteral: 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var actual = impulse
        let equalizer = try PeakingEqualizer(frequency: frequency, gain: gain, q: q)
        try equalizer.process(&actual, horizon: actual.count, circular: false)
        let expected = referencePeaking(impulse, frequency: frequency, gain: gain, q: q)
        #expect(approximatelyEqual(actual, expected, tolerance: 0.00001))

        let period = (0..<64).map { index in
            Float(sin(Double(index) * 0.31))
        }
        var periodic = period
        try equalizer.process(&periodic, horizon: period.count, circular: true)
        let warmup = Array(repeating: period, count: 32).flatMap { $0 }
        let expectedWarmup = referencePeaking(warmup, frequency: frequency, gain: gain, q: q)
        #expect(approximatelyEqual(periodic, Array(expectedWarmup.suffix(period.count)), tolerance: 0.0001))
    }

    @Test(.timeLimit(.minutes(3)))
    func reverbIsDeterministicStereoAndWetMixExtendsOnlyTheLoopHorizon() throws {
        let roomSize = 0.15
        let frameCount = 32_000
        let dryInput = impulseBuffer(frameCount: frameCount)
        let dry = dryInput

        var wet = dryInput
        let wetEffect = AudioEffect.reverb(roomSize: roomSize, wet: 1)
        let convolver = try FFTConvolver(maximumLinearFrameCount: 65_536)
        try EffectProcessor.apply(
            wetEffect, to: &wet, inputHorizon: 1,
            bpm: 120, seamless: false, node: 0, convolver: convolver
        )

        var repeated = dryInput
        try EffectProcessor.apply(
            wetEffect, to: &repeated, inputHorizon: 1,
            bpm: 120, seamless: false, node: 0, convolver: convolver
        )
        #expect(approximatelyEqual(wet.left, repeated.left, tolerance: 0.000001))
        #expect(approximatelyEqual(wet.right, repeated.right, tolerance: 0.000001))
        #expect(wet.left.enumerated().contains { index, value in
            abs(value - wet.right[index]) > 0.000001
        })
        #expect(wet.left.contains { abs($0) > 0.000001 })

        var mixed = dryInput
        try EffectProcessor.apply(
            .reverb(roomSize: roomSize, wet: 0.5), to: &mixed, inputHorizon: 1,
            bpm: 120, seamless: false, node: 0, convolver: convolver
        )
        #expect(mixed.left.enumerated().allSatisfy { index, value in
            abs(value - (dry.left[index] * 0.5 + wet.left[index] * 0.5)) < 0.0001
        })

        let sound = Synthesizer(.sine).notes("C4")
        let baseline = try LoopRenderer().render(
            SoundCompiler().compile(sound), bpm: 120, beatsPerBar: 4
        )
        let reverberated = try LoopRenderer().render(
            SoundCompiler().compile(sound.effect(.reverb(roomSize: roomSize, wet: 1))),
            bpm: 120, beatsPerBar: 4
        )
        #expect(reverberated.beatCount > baseline.beatCount)
        #expect(reverberated.samples.count > baseline.samples.count)
        #expect(reverberated.events.map(\.durationBeats) == baseline.events.map(\.durationBeats))
    }

    @Test(.timeLimit(.minutes(3)))
    func neutralEffectsPreservePCMAndDoNotPadAtNonIntegerSampleBeat() throws {
        let sound = Synthesizer(.sine).notes("C4")
        let baseline = try LoopRenderer().render(
            SoundCompiler().compile(sound), bpm: 137, beatsPerBar: 4
        )
        let neutral = try LoopRenderer().render(
            SoundCompiler().compile(
                sound
                    .effect(.saturation(drive: 0))
                    .effect(.reverb(roomSize: 0.8, wet: 0))
            ),
            bpm: 137, beatsPerBar: 4
        )
        #expect(neutral.beatCount == baseline.beatCount)
        #expect(neutral.samples == baseline.samples)
        #expect(neutral.events == baseline.events)
    }

    private func impulseBuffer(frameCount: Int) -> StereoBuffer {
        var result = StereoBuffer(frameCount: frameCount)
        result.left[0] = 1
        result.right[0] = 1
        return result
    }

    private func approximatelyEqual(_ lhs: [Float], _ rhs: [Float], tolerance: Float = 0.0001) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.enumerated().allSatisfy { index, value in
            abs(value - rhs[index]) <= tolerance
        }
    }

    private func referencePeaking(
        _ input: [Float], frequency: Double, gain: Double, q: Double
    ) -> [Float] {
        let amplitude = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha / amplitude
        let b0 = (1 + alpha * amplitude) / a0
        let b1 = -2 * cos(omega) / a0
        let b2 = (1 - alpha * amplitude) / a0
        let a1 = b1
        let a2 = (1 - alpha / amplitude) / a0
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
        return input.map { value in
            let x0 = Double(value)
            let output = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = output
            return Float(output)
        }
    }
}
