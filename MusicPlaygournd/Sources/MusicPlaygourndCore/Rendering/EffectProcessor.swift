import Foundation
import SwiftMusic

/// Applies ordered graph effects through their bounded offline DSP owners.
internal enum EffectProcessor {
    static let maximumTailFrames = Int(PreparedLoop.requiredSampleRate * PreparedLoop.maximumDurationSeconds)

    static func tailFrames(_ effect: AudioEffect, bpm: Double, node: Int) throws -> Int {
        switch effect {
        case .equalizer, .saturation, .distortion, .compressor, .sidechainCompressor, .noiseGate, .limiter: return 0
        case .delay(let time, let feedback, let wet):
            return wet == 0 ? 0 : try delay(time, feedback: feedback, bpm: bpm).last
        case .reverb(let size, let wet):
            return wet == 0 ? 0 : Int(((0.1 + 2.9 * size) * PreparedLoop.requiredSampleRate).rounded(.up)) - 1
        case .filter(let kind, let cutoff, let resonance):
            _ = try PeakingEqualizer(filter: kind, cutoff: cutoff, resonance: resonance)
            return 0
        case .chorus, .flanger, .phaser, .stereoWidth:
            return try ModulationProcessor.tailFrames(effect)
        }
    }

    private static func delay(_ time: MusicalTime, feedback: Double, bpm: Double) throws -> (count: Int, frames: Double, last: Int) {
        let frames = Double(time.numerator) / Double(time.denominator) * 60 / bpm * PreparedLoop.requiredSampleRate
        guard frames.isFinite, frames.rounded() >= 1, frames <= Double(maximumTailFrames),
              feedback.isFinite, (0..<1).contains(feedback) else {
            throw LoopRenderingError.invalidSound("delay time or feedback exceeds the finite tail bound")
        }
        let count = feedback == 0 ? 1 : floor(log(1e-5) / log(feedback)) + 1
        guard count.isFinite, count >= 1, count <= Double(maximumTailFrames) / frames,
              (count * frames).rounded() <= Double(maximumTailFrames) else {
            throw LoopRenderingError.invalidSound("delay tail exceeds 16 seconds")
        }
        return (Int(count), frames, Int((count * frames).rounded()))
    }

    static func apply(_ effect: AudioEffect, to buffer: inout StereoBuffer,
                      inputHorizon: Int, bpm: Double, seamless: Bool,
                      node: Int, convolver: FFTConvolver?) throws {
        guard buffer.left.count == buffer.right.count,
              inputHorizon >= 0, inputHorizon <= buffer.left.count,
              buffer.left.allSatisfy({ $0.isFinite }), buffer.right.allSatisfy({ $0.isFinite }) else {
            throw LoopRenderingError.invalidSound("invalid effect input PCM")
        }
        switch effect {
        case .compressor, .sidechainCompressor, .noiseGate, .limiter:
            try DynamicsProcessor(effect).process(&buffer, seamless: seamless)
        case .chorus, .flanger, .phaser, .stereoWidth:
            try ModulationProcessor.process(
                effect,
                buffer: &buffer,
                inputHorizon: inputHorizon,
                seamless: seamless
            )
        case .filter(let kind, let cutoff, let resonance):
            let filter = try PeakingEqualizer(filter: kind, cutoff: cutoff, resonance: resonance)
            try filter.process(&buffer.left, horizon: inputHorizon, circular: seamless)
            try filter.process(&buffer.right, horizon: inputHorizon, circular: seamless)
        case .equalizer(let frequency, let gain, let q):
            let eq = try PeakingEqualizer(frequency: frequency, gain: gain, q: q)
            try eq.process(&buffer.left, horizon: inputHorizon, circular: seamless)
            try eq.process(&buffer.right, horizon: inputHorizon, circular: seamless)
        case .saturation(let drive), .distortion(let drive):
            guard drive != 0 else { return }
            for index in buffer.left.indices {
                func shaped(_ input: Float) throws -> Float {
                    let x = Double(input)
                    let numerator = x * (1 + drive)
                    guard numerator.isFinite else { throw LoopRenderingError.invalidSound("non-finite shaped PCM") }
                    let output: Double
                    switch effect {
                    case .saturation:
                        let denominator = 1 + drive * abs(x)
                        guard denominator.isFinite else { throw LoopRenderingError.invalidSound("non-finite shaped PCM") }
                        output = numerator / denominator
                    default: output = min(1, max(-1, numerator))
                    }
                    guard output.isFinite, abs(output) <= Double(Float.greatestFiniteMagnitude) else {
                        throw LoopRenderingError.invalidSound("non-finite shaped PCM")
                    }
                    return Float(output)
                }
                buffer.left[index] = try shaped(buffer.left[index])
                buffer.right[index] = try shaped(buffer.right[index])
            }
        case .delay(let time, let feedback, let wet):
            guard wet != 0 else { return }
            let taps = try delay(time, feedback: feedback, bpm: bpm)
            var impulse = [Float](repeating: 0, count: taps.last + 1)
            for tap in 0..<taps.count {
                let offset = Int((taps.frames * Double(tap + 1)).rounded())
                impulse[offset] += Float(pow(feedback, Double(tap)))
            }
            try convolve(&buffer, leftIR: impulse, rightIR: impulse, wet: wet,
                         seamless: seamless, convolver: convolver)
        case .reverb(let roomSize, let wet):
            guard wet != 0 else { return }
            try convolve(&buffer, leftIR: impulse(roomSize: roomSize, right: false),
                         rightIR: impulse(roomSize: roomSize, right: true), wet: wet,
                         seamless: seamless, convolver: convolver)
        }
        guard buffer.left.allSatisfy({ $0.isFinite }), buffer.right.allSatisfy({ $0.isFinite }) else {
            throw LoopRenderingError.invalidSound("non-finite effect PCM")
        }
    }

    private static func convolve(_ buffer: inout StereoBuffer, leftIR: [Float], rightIR: [Float],
                                 wet: Double, seamless: Bool, convolver: FFTConvolver?) throws {
        guard let convolver else { throw LoopRenderingError.invalidSound("effect has no convolution workspace") }
        let left = try convolver.convolve(buffer.left, with: leftIR, outputFrameCount: buffer.left.count, circular: seamless)
        let right = try convolver.convolve(buffer.right, with: rightIR, outputFrameCount: buffer.right.count, circular: seamless)
        for index in buffer.left.indices {
            buffer.left[index] = buffer.left[index] * Float(1 - wet) + left[index] * Float(wet)
            buffer.right[index] = buffer.right[index] * Float(1 - wet) + right[index] * Float(wet)
        }
    }

    private static func impulse(roomSize: Double, right: Bool) -> [Float] {
        let rate = PreparedLoop.requiredSampleRate
        let scale = 0.5 + roomSize
        let count = Int(((0.1 + 2.9 * roomSize) * rate).rounded(.up))
        let feedback = 0.2 + 0.75 * roomSize
        let combDelays = [0.0297, 0.0371, 0.0411, 0.0437].map {
            Int(($0 * scale * rate).rounded()) + (right ? 1 : 0)
        }
        var result = [Float](repeating: 0, count: count)
        for delay in combDelays {
            var ring = [Double](repeating: 0, count: delay)
            for frame in 0..<count {
                let index = frame % delay
                let delayed = ring[index]
                ring[index] = (frame == 0 ? 1 : 0) + feedback * delayed
                result[frame] += Float(delayed / 4)
            }
        }
        for seconds in [0.005, 0.0017] {
            let delay = Int((seconds * scale * rate).rounded()) + (right ? 1 : 0)
            var ring = [Double](repeating: 0, count: delay)
            for frame in 0..<count {
                let index = frame % delay
                let input = Double(result[frame])
                let output = ring[index] - 0.5 * input
                ring[index] = input + 0.5 * output
                result[frame] = Float(output)
            }
        }
        return result
    }
}
