import Foundation
import SwiftMusic

/// Bounded off-callback modulation; each channel owns its causal state.
internal enum ModulationProcessor {
    static func tailFrames(_ effect: AudioEffect) throws -> Int {
        switch effect {
        case .chorus(let rate, let depth, let wet):
            try validateRate(rate, wet: wet)
            guard depth.isFinite, (0...1).contains(depth) else { throw invalid() }
            return wet == 0 ? 0 : Int(ceil((0.015 + 0.01 * depth) * PreparedLoop.requiredSampleRate))
        case .flanger(let rate, let delay, let depth, let feedback, let wet):
            try validateRate(rate, wet: wet)
            guard delay.isFinite, depth.isFinite, depth >= 0, delay > depth,
                  feedback.isFinite, abs(feedback) < 1 else { throw invalid() }
            guard wet != 0 else { return 0 }
            let minimum = (delay - depth) * PreparedLoop.requiredSampleRate
            let maximum = (delay + depth) * PreparedLoop.requiredSampleRate
            let count = feedback == 0 ? 1 : floor(log(1e-5) / log(abs(feedback))) + 1
            let tail = count * ceil(maximum)
            guard minimum >= 1, maximum.isFinite, maximum <= Double(EffectProcessor.maximumTailFrames),
                  tail.isFinite, tail > 0, tail <= Double(EffectProcessor.maximumTailFrames) else {
                throw LoopRenderingError.invalidSound("flanger delay or tail exceeds its causal frame bound")
            }
            return Int(tail)
        case .phaser(let rate, let minimum, let maximum, let stages, let feedback, let wet):
            try validateRate(rate, wet: wet)
            guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum > minimum,
                  maximum < PreparedLoop.requiredSampleRate / 2, (1...32).contains(stages),
                  feedback.isFinite, abs(feedback) < 1 else { throw invalid() }
            return 0
        case .stereoWidth(let width):
            guard width.isFinite, width >= 0 else { throw invalid() }
            return 0
        default: throw invalid()
        }
    }

    static func process(
        _ effect: AudioEffect,
        buffer: inout StereoBuffer,
        inputHorizon: Int,
        seamless: Bool
    ) throws {
        guard buffer.left.count == buffer.right.count,
              inputHorizon >= 0, inputHorizon <= buffer.left.count else {
            throw invalid()
        }
        let tail = try tailFrames(effect)
        switch effect {
        case .chorus(let rate, let depth, let wet):
            guard wet != 0 else { return }
            try validateCycles(rate, frames: buffer.left.count, seamless: seamless)
            let frameCount = try ownedFrameCount(
                inputHorizon: inputHorizon, tail: tail, bufferCount: buffer.left.count,
                seamless: seamless
            )
            try chorus(&buffer.left, rate: rate, depth: depth, wet: wet, phase: 0,
                       frameCount: frameCount, seamless: seamless)
            try chorus(&buffer.right, rate: rate, depth: depth, wet: wet, phase: 0.25,
                       frameCount: frameCount, seamless: seamless)
            zeroAfter(frameCount, in: &buffer)
        case .flanger(let rate, let delay, let depth, let feedback, let wet):
            guard wet != 0 else { return }
            try validateCycles(rate, frames: buffer.left.count, seamless: seamless)
            let frameCount = try ownedFrameCount(
                inputHorizon: inputHorizon, tail: tail, bufferCount: buffer.left.count,
                seamless: seamless
            )
            let ringCount = Int(ceil((delay + depth) * PreparedLoop.requiredSampleRate)) + 2
            try flanger(&buffer.left, rate: rate, delay: delay, depth: depth,
                        feedback: feedback, wet: wet, ringCount: ringCount,
                        frameCount: frameCount, seamless: seamless)
            try flanger(&buffer.right, rate: rate, delay: delay, depth: depth,
                        feedback: feedback, wet: wet, ringCount: ringCount,
                        frameCount: frameCount, seamless: seamless)
            zeroAfter(frameCount, in: &buffer)
        case .phaser(let rate, let minimum, let maximum, let stages, let feedback, let wet):
            guard wet != 0 else { return }
            try validateCycles(rate, frames: buffer.left.count, seamless: seamless)
            let frameCount = try ownedFrameCount(
                inputHorizon: inputHorizon, tail: tail, bufferCount: buffer.left.count,
                seamless: seamless
            )
            try phaser(&buffer.left, rate: rate, minimum: minimum, maximum: maximum,
                       stages: stages, feedback: feedback, wet: wet,
                       frameCount: frameCount, seamless: seamless)
            try phaser(&buffer.right, rate: rate, minimum: minimum, maximum: maximum,
                       stages: stages, feedback: feedback, wet: wet,
                       frameCount: frameCount, seamless: seamless)
            zeroAfter(frameCount, in: &buffer)
        case .stereoWidth(let width):
            guard width != 1 else { return }
            let frameCount = try ownedFrameCount(
                inputHorizon: inputHorizon, tail: tail, bufferCount: buffer.left.count,
                seamless: seamless
            )
            for index in 0..<frameCount {
                let left = Double(buffer.left[index]), right = Double(buffer.right[index])
                let mid = (left + right) / 2, side = (left - right) / 2 * width
                buffer.left[index] = try pcm(mid + side)
                buffer.right[index] = try pcm(mid - side)
            }
            zeroAfter(frameCount, in: &buffer)
        default: throw invalid()
        }
    }

    private static func chorus(_ samples: inout [Float], rate: Double, depth: Double,
                               wet: Double, phase: Double, frameCount: Int,
                               seamless: Bool) throws {
        // One channel snapshot keeps interpolation independent of output mutation.
        let input = samples
        for index in 0..<frameCount {
            let delay = (0.015 + sin(2 * .pi * (phaseCycles(index, rate: rate) + phase)) * 0.01 * depth)
                * PreparedLoop.requiredSampleRate
            let position = Double(index) - delay
            let floorPosition = floor(position)
            let first = Int(floorPosition), fraction = position - floorPosition
            func sample(_ index: Int) -> Double {
                if seamless { return Double(input[(index % input.count + input.count) % input.count]) }
                return input.indices.contains(index) ? Double(input[index]) : 0
            }
            let delayed = sample(first) * (1 - fraction) + sample(first + 1) * fraction
            samples[index] = try pcm(Double(input[index]) * (1 - wet) + delayed * wet)
        }
    }

    private struct DelayState {
        var ring: [Double]
        var write = 0
        mutating func advance(_ input: Double, delay: Double, feedback: Double) throws -> Double {
            let whole = Int(delay.rounded(.down)), fraction = delay - Double(whole)
            let first = (write - whole % ring.count + ring.count) % ring.count
            let second = (first - 1 + ring.count) % ring.count
            let delayed = ring[first] * (1 - fraction) + ring[second] * fraction
            let stored = input + feedback * delayed
            guard stored.isFinite else { throw invalid() }
            ring[write] = stored
            write = (write + 1) % ring.count
            return delayed
        }
        func matches(_ other: Self) -> Bool {
            for lag in ring.indices {
                let a = ring[(write + lag) % ring.count]
                let b = other.ring[(other.write + lag) % other.ring.count]
                if !a.isFinite || abs(a - b) > 1e-12 * max(1, max(abs(a), abs(b))) { return false }
            }
            return true
        }
    }

    private static func flanger(_ samples: inout [Float], rate: Double, delay: Double,
                                depth: Double, feedback: Double, wet: Double,
                                ringCount: Int, frameCount: Int, seamless: Bool) throws {
        var state = DelayState(ring: Array(repeating: 0, count: ringCount))
        func delayFrames(_ index: Int) -> Double {
            (delay + depth * sin(2 * .pi * phaseCycles(index, rate: rate)))
                * PreparedLoop.requiredSampleRate
        }
        if seamless {
            var verified = false
            for _ in 0..<64 {
                let previous = state
                for index in 0..<frameCount {
                    _ = try state.advance(Double(samples[index]), delay: delayFrames(index), feedback: feedback)
                }
                if state.matches(previous) { verified = true; break }
            }
            guard verified else { throw LoopRenderingError.nonPeriodicModulationState }
        }
        for index in 0..<frameCount {
            let input = Double(samples[index])
            let delayed = try state.advance(input, delay: delayFrames(index), feedback: feedback)
            samples[index] = try pcm(input * (1 - wet) + delayed * wet)
        }
    }

    private struct PhaserState {
        var inputs: [Double]
        var outputs: [Double]
        var feedbackSample = 0.0
        mutating func advance(_ input: Double, coefficient: Double, feedback: Double) throws -> Double {
            var value = input + feedback * feedbackSample
            for index in inputs.indices {
                let output = coefficient * value + inputs[index] - coefficient * outputs[index]
                inputs[index] = value
                outputs[index] = output
                value = output
                guard value.isFinite else { throw invalid() }
            }
            feedbackSample = value
            return value
        }
        func matches(_ other: Self) -> Bool {
            for index in inputs.indices {
                if abs(inputs[index] - other.inputs[index]) > 1e-12 * max(1, max(abs(inputs[index]), abs(other.inputs[index]))) { return false }
                if abs(outputs[index] - other.outputs[index]) > 1e-12 * max(1, max(abs(outputs[index]), abs(other.outputs[index]))) { return false }
            }
            return abs(feedbackSample - other.feedbackSample)
                <= 1e-12 * max(1, max(abs(feedbackSample), abs(other.feedbackSample)))
        }
    }

    private static func phaser(_ samples: inout [Float], rate: Double, minimum: Double,
                               maximum: Double, stages: Int, feedback: Double,
                               wet: Double, frameCount: Int, seamless: Bool) throws {
        var state = PhaserState(inputs: Array(repeating: 0, count: stages),
                                outputs: Array(repeating: 0, count: stages))
        func coefficient(_ index: Int) -> Double {
            let phase = (1 + sin(2 * .pi * phaseCycles(index, rate: rate))) / 2
            let frequency = minimum + (maximum - minimum) * phase
            let tangent = tan(.pi * frequency / PreparedLoop.requiredSampleRate)
            return (tangent - 1) / (tangent + 1)
        }
        if seamless {
            var verified = false
            for _ in 0..<64 {
                let previous = state
                for index in 0..<frameCount {
                    _ = try state.advance(Double(samples[index]), coefficient: coefficient(index), feedback: feedback)
                }
                if state.matches(previous) { verified = true; break }
            }
            guard verified else { throw LoopRenderingError.nonPeriodicModulationState }
        }
        for index in 0..<frameCount {
            let input = Double(samples[index])
            let effected = try state.advance(input, coefficient: coefficient(index), feedback: feedback)
            samples[index] = try pcm(input * (1 - wet) + effected * wet)
        }
    }

    private static func phaseCycles(_ frame: Int, rate: Double) -> Double {
        // Reduce the sampled phase increment before multiplication to avoid finite-rate overflow.
        let increment = rate.truncatingRemainder(dividingBy: PreparedLoop.requiredSampleRate)
            / PreparedLoop.requiredSampleRate
        return (Double(frame) * increment).truncatingRemainder(dividingBy: 1)
    }

    private static func validateRate(_ rate: Double, wet: Double) throws {
        guard rate.isFinite, rate > 0, wet.isFinite, (0...1).contains(wet) else { throw invalid() }
    }

    private static func ownedFrameCount(
        inputHorizon: Int,
        tail: Int,
        bufferCount: Int,
        seamless: Bool
    ) throws -> Int {
        guard !seamless else { return bufferCount }
        let (owned, overflow) = inputHorizon.addingReportingOverflow(tail)
        guard !overflow else { throw invalid() }
        return min(bufferCount, owned)
    }

    private static func zeroAfter(_ frameCount: Int, in buffer: inout StereoBuffer) {
        guard frameCount < buffer.left.count else { return }
        for index in frameCount..<buffer.left.count {
            buffer.left[index] = 0
            buffer.right[index] = 0
        }
    }

    private static func validateCycles(_ rate: Double, frames: Int, seamless: Bool) throws {
        guard seamless else { return }
        let cycles = rate * Double(frames) / PreparedLoop.requiredSampleRate
        guard cycles.isFinite, cycles.rounded() >= 1, abs(cycles - cycles.rounded()) <= 1e-10 else {
            throw LoopRenderingError.nonPeriodicModulationState
        }
    }

    private static func pcm(_ value: Double) throws -> Float {
        guard value.isFinite, abs(value) <= Double(Float.greatestFiniteMagnitude) else { throw invalid() }
        return Float(value)
    }

    private static func invalid() -> LoopRenderingError {
        .invalidSound("invalid modulation parameters or state")
    }
}
