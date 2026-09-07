import Foundation
import SwiftMusic

/// Stereo-linked dynamics with a verified periodic scalar state for loop rendering.
internal struct DynamicsProcessor {
    private enum Mode { case compressor, gate, limiter }
    private let mode: Mode
    private let threshold: Double
    private let ratio: Double
    private let knee: Double
    private let attack: Double
    private let release: Double
    private let ceiling: Double

    init(_ effect: AudioEffect) throws {
        let attackSeconds: Double
        let releaseSeconds: Double
        switch effect {
        case .compressor(let threshold, let ratio):
            mode = .compressor; self.threshold = threshold; self.ratio = ratio; knee = 0
            attackSeconds = 0; releaseSeconds = 0; ceiling = 1
        case .sidechainCompressor(let value):
            mode = .compressor; threshold = value.thresholdDecibels; ratio = value.ratio
            knee = value.kneeDecibels; attackSeconds = value.attackSeconds
            releaseSeconds = value.releaseSeconds; ceiling = 1
        case .noiseGate(let value):
            mode = .gate; threshold = value.thresholdDecibels; ratio = 1; knee = 0
            attackSeconds = value.attackSeconds; releaseSeconds = value.releaseSeconds; ceiling = 1
        case .limiter(let value):
            mode = .limiter; threshold = value.ceilingDecibels; ratio = 1; knee = 0
            attackSeconds = 0; releaseSeconds = value.releaseSeconds
            ceiling = pow(10, value.ceilingDecibels / 20)
        default:
            throw LoopRenderingError.invalidSound("invalid dynamics descriptor")
        }
        guard threshold.isFinite, ratio.isFinite, ratio >= 1, knee.isFinite, knee >= 0,
              ceiling.isFinite, ceiling >= 0 else {
            throw LoopRenderingError.invalidSound("invalid dynamics parameters")
        }
        func coefficient(_ seconds: Double) throws -> Double {
            guard seconds.isFinite, seconds >= 0 else {
                throw LoopRenderingError.invalidSound("invalid dynamics duration")
            }
            return seconds == 0 ? 0 : exp(-1 / (seconds * PreparedLoop.requiredSampleRate))
        }
        attack = try coefficient(attackSeconds)
        release = try coefficient(releaseSeconds)
    }

    private func step(peak: Double, state: inout Double) throws -> Double {
        let gain: Double
        switch mode {
        case .compressor:
            let coefficient = peak > state ? attack : release
            state = peak + coefficient * (state - peak)
            if state == 0 || ratio == 1 { gain = 1 }
            else {
                let difference = 20 * log10(state) - threshold
                let reduction: Double
                if knee == 0 {
                    reduction = (1 / ratio - 1) * max(0, difference)
                } else if difference <= -knee / 2 { reduction = 0 }
                else if difference >= knee / 2 { reduction = (1 / ratio - 1) * difference }
                else {
                    let position = difference + knee / 2
                    reduction = (1 / ratio - 1) * position * (position / knee) / 2
                }
                guard reduction.isFinite else { throw LoopRenderingError.invalidSound("non-finite compressor reduction") }
                gain = pow(10, reduction / 20)
            }
        case .gate:
            let target = peak > 0 && 20 * log10(peak) >= threshold ? 1.0 : 0.0
            let coefficient = target > state ? attack : release
            state = target + coefficient * (state - target)
            gain = state
        case .limiter:
            let target = peak == 0 ? 1 : min(1, ceiling / peak)
            state = target < state ? target : target + release * (state - target)
            gain = min(target, state)
        }
        guard state.isFinite, state >= 0, gain.isFinite, (0...1).contains(gain) else {
            throw LoopRenderingError.invalidSound("non-finite dynamics state")
        }
        return gain
    }

    @discardableResult
    func process(_ buffer: inout StereoBuffer, sidechain: StereoBuffer? = nil,
                 seamless: Bool) throws -> (initial: Double, final: Double) {
        guard !buffer.left.isEmpty, buffer.left.count == buffer.right.count,
              sidechain.map({ $0.left.count == buffer.left.count && $0.right.count == buffer.right.count }) ?? true else {
            throw LoopRenderingError.invalidSound("dynamics channel lengths disagree")
        }
        func peak(_ frame: Int) throws -> Double {
            let left = sidechain?.left[frame] ?? buffer.left[frame]
            let right = sidechain?.right[frame] ?? buffer.right[frame]
            guard left.isFinite, right.isFinite else { throw LoopRenderingError.invalidSound("non-finite dynamics detector") }
            return max(abs(Double(left)), abs(Double(right)))
        }
        var maximum = 0.0
        for frame in buffer.left.indices { maximum = max(maximum, try peak(frame)) }
        var state = mode == .limiter ? 1.0 : 0.0
        if seamless {
            // A coefficient below one makes each scalar update contractive.
            guard attack < 1, release < 1 else { throw LoopRenderingError.nonPeriodicDynamicsState }
            var lower = 0.0
            var upper = mode == .compressor ? maximum : 1.0
            var solved = false
            if attack == 0 && release == 0 {
                // Instantaneous updates erase all history; the last detector
                // sample gives the exact periodic state without iteration.
                _ = try step(peak: peak(buffer.left.count - 1), state: &state)
                solved = true
            }
            for _ in 0..<(solved ? 0 : 64) {
                let candidate = lower + (upper - lower) / 2
                var end = candidate
                for frame in buffer.left.indices { _ = try step(peak: peak(frame), state: &end) }
                let residual = end - candidate
                if abs(residual) <= 1e-12 * max(1, abs(candidate)) {
                    state = candidate; solved = true; break
                }
                if residual > 0 { lower = candidate } else { upper = candidate }
            }
            guard solved else { throw LoopRenderingError.nonPeriodicDynamicsState }
        }
        let initial = state
        var floatCeiling = Float(ceiling)
        if Double(floatCeiling) > ceiling { floatCeiling = floatCeiling.nextDown }
        for frame in buffer.left.indices {
            let gain = try step(peak: peak(frame), state: &state)
            let left = Double(buffer.left[frame]) * gain
            let right = Double(buffer.right[frame]) * gain
            guard left.isFinite, right.isFinite,
                  abs(left) <= Double(Float.greatestFiniteMagnitude),
                  abs(right) <= Double(Float.greatestFiniteMagnitude) else {
                throw LoopRenderingError.invalidSound("non-finite dynamics PCM")
            }
            buffer.left[frame] = Float(left)
            buffer.right[frame] = Float(right)
            if mode == .limiter {
                buffer.left[frame] = min(floatCeiling, max(-floatCeiling, buffer.left[frame]))
                buffer.right[frame] = min(floatCeiling, max(-floatCeiling, buffer.right[frame]))
            }
        }
        if seamless, abs(state - initial) > 1e-12 * max(1, abs(initial)) {
            throw LoopRenderingError.nonPeriodicDynamicsState
        }
        return (initial, state)
    }

    static func duck(_ buffer: inout StereoBuffer, rules: [Int], sound: CompiledSound,
                     secondsPerBeat: Double, seamless: Bool) throws {
        let rate = PreparedLoop.requiredSampleRate
        let count = buffer.left.count
        var gains = [Double](repeating: 1, count: count)
        for index in rules {
            guard sound.eventDucks.indices.contains(index) else {
                throw LoopRenderingError.invalidSound("duck rule index is invalid")
            }
            let rule = sound.eventDucks[index]
            guard sound.events.indices.contains(rule.triggerEventIndex),
                  rule.depthDecibels.isFinite, rule.depthDecibels <= 0,
                  rule.attackSeconds.isFinite, rule.attackSeconds >= 0,
                  rule.recoverySeconds.isFinite, rule.recoverySeconds > 0 else {
                throw LoopRenderingError.invalidSound("invalid event duck rule")
            }
            let duration = rule.attackSeconds + rule.recoverySeconds
            guard duration.isFinite,
                  !seamless || duration <= Double(count) / rate else {
                throw LoopRenderingError.invalidSound("duck envelope exceeds loop window")
            }
            let event = sound.events[rule.triggerEventIndex]
            let onset = Double(event.start.numerator) / Double(event.start.denominator) * secondsPerBeat * rate
            guard onset.isFinite, onset >= 0, onset < Double(count) else {
                throw LoopRenderingError.invalidSound("duck onset is outside loop")
            }
            let start = Int(onset.rounded(.down))
            let frames = min(count, Int(min(Double(count), (duration * rate).rounded(.up))))
            let depth = pow(10, rule.depthDecibels / 20)
            for offset in 0..<frames {
                let frame = start + offset
                if !seamless, frame >= count { break }
                let seconds = Double(offset) / rate
                let gain: Double
                if seconds < rule.attackSeconds {
                    gain = 1 + (depth - 1) * (seconds / rule.attackSeconds)
                } else {
                    gain = depth + (1 - depth) * min(1, (seconds - rule.attackSeconds) / rule.recoverySeconds)
                }
                gains[frame % count] = min(gains[frame % count], gain)
            }
        }
        for frame in buffer.left.indices {
            buffer.left[frame] *= Float(gains[frame])
            buffer.right[frame] *= Float(gains[frame])
        }
    }

}
