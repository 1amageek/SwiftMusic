import Foundation
import SwiftMusic

/// A bounded ring of grain cursors; copies occur only at voice/scheduler snapshot boundaries.
internal struct GranularSampleVoice: Equatable {
    struct Grain: Equatable {
        var age = -1
        var position = 0.0
    }
    let grainFrames: Int
    let hop: Int
    let jitter: Double
    let seed: UInt64
    let sourceID: Int
    let eventIndex: Int
    var grains: [Grain]
    var ordinal = 0

    static func dimensions(_ configuration: GranularPlayback, eventFrames: Int) throws
        -> (frames: Int, hop: Int, slots: Int, launches: Int) {
        let duration = configuration.grainDuration.components
        let frames = (Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
            * PreparedLoop.requiredSampleRate
        guard frames.isFinite, frames >= 2,
              frames <= Double(SamplePreparation.maximumChannelFrames) else {
            throw LoopRenderingError.invalidSound("granular duration or overlap exceeds frame bounds")
        }
        let count = Int(frames.rounded(.up))
        let hop = (Double(count) * (1 - configuration.overlap)).rounded(.down)
        guard hop >= 1 else {
            throw LoopRenderingError.invalidSound("granular hop must resolve to at least one frame")
        }
        let stride = Int(hop)
        let slots = (count - 1) / stride + 1
        let launches = (eventFrames - 1) / stride + 1
        guard eventFrames > 0, slots <= 4096, launches <= 4096 else {
            throw LoopRenderingError.invalidSound("granular voice exceeds 4096 grains")
        }
        return (count, stride, slots, launches)
    }

    init(_ configuration: GranularPlayback, eventFrames: Int, sourceID: Int, eventIndex: Int) throws {
        let dimensions = try Self.dimensions(configuration, eventFrames: eventFrames)
        grainFrames = dimensions.frames
        hop = dimensions.hop
        jitter = configuration.positionJitter * Double(grainFrames)
        seed = configuration.seed
        self.sourceID = sourceID
        self.eventIndex = eventIndex
        grains = [Grain](repeating: Grain(), count: dimensions.slots)
    }

    mutating func next(sample: PreparedSampleVoice, offset: Int, scan: Double,
                       increment: Double, reversed: Bool) throws -> (Double, Double) {
        if offset % hop == 0 {
            let slot = ordinal % grains.count
            let random = GranularDeterministicRandom.value(seed: seed, sourceID: sourceID,
                eventIndex: eventIndex, ordinal: ordinal)
            grains[slot] = Grain(age: 0, position: scan + random * jitter)
            ordinal += 1
        }
        var left = 0.0
        var right = 0.0
        var weight = 0.0
        for index in grains.indices where grains[index].age >= 0 && grains[index].age < grainFrames {
            let age = grains[index].age
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(age) / Double(grainFrames - 1))
            let position = grains[index].position
            guard position.isFinite, increment.isFinite, increment > 0 else {
                throw LoopRenderingError.invalidSound("non-finite granular traversal")
            }
            if position >= 0, position <= Double(sample.frameCount - 1) {
                left += window * sample.value(at: position, reversed: reversed, channel: 0)
                right += window * sample.value(at: position, reversed: reversed, channel: 1)
            }
            weight += window
            grains[index].age += 1
            grains[index].position += increment
        }
        guard left.isFinite, right.isFinite, weight.isFinite else {
            throw LoopRenderingError.invalidSound("non-finite granular overlap")
        }
        return weight > 0 ? (left / weight, right / weight) : (0, 0)
    }
}

private enum GranularDeterministicRandom {
    static func value(seed: UInt64, sourceID: Int, eventIndex: Int, ordinal: Int) -> Double {
        // SplitMix64 with explicit stable identities; wrapping arithmetic is intentional.
        var value = seed &+ 0x9E3779B97F4A7C15 &* (UInt64(ordinal) &+ 1)
            &+ 0xD1B54A32D192ED03 &* UInt64(sourceID)
            &+ 0x94D049BB133111EB &* UInt64(eventIndex)
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992 * 2 - 1
    }
}
