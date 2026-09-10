import Foundation

public enum AudioEffect: Sendable, Equatable, Hashable {
    public static func equalizer(frequency: Frequency, gain: Decibels, q: Double) -> Self {
        .equalizer(frequencyHz: frequency.hertz, gainDecibels: gain.value, q: q)
    }

    public static func compressor(threshold: Decibels, ratio: Double) -> Self {
        .compressor(thresholdDecibels: threshold.value, ratio: ratio)
    }

    public static func filter(
        kind: FilterKind,
        cutoff: Frequency,
        resonance: Double
    ) -> Self {
        .filter(kind: kind, cutoffHz: cutoff.hertz, resonance: resonance)
    }

    public static func chorus(
        rate: Frequency,
        depth: Double,
        wet: Double
    ) -> Self {
        .chorus(rateHz: rate.hertz, depth: depth, wet: wet)
    }

    public static func flanger(
        rate: Frequency,
        delay: Duration,
        depth: Duration,
        feedback: Double,
        wet: Double
    ) throws -> Self {
        .flanger(
            rateHz: rate.hertz,
            delaySeconds: try _dynamicsDurationSeconds(delay),
            depthSeconds: try _dynamicsDurationSeconds(depth),
            feedback: feedback,
            wet: wet
        )
    }

    public static func phaser(
        rate: Frequency,
        minimum: Frequency,
        maximum: Frequency,
        stages: Int,
        feedback: Double,
        wet: Double
    ) -> Self {
        .phaser(
            rateHz: rate.hertz,
            minimumHz: minimum.hertz,
            maximumHz: maximum.hertz,
            stages: stages,
            feedback: feedback,
            wet: wet
        )
    }

    case equalizer(frequencyHz: Double, gainDecibels: Double, q: Double)
    case filter(kind: FilterKind, cutoffHz: Double, resonance: Double)
    case compressor(thresholdDecibels: Double, ratio: Double)
    case sidechainCompressor(SidechainCompressor)
    case noiseGate(NoiseGate)
    case limiter(Limiter)
    case saturation(drive: Double)
    case distortion(drive: Double)
    case delay(time: MusicalTime, feedback: Double, wet: Double)
    case reverb(roomSize: Double, wet: Double)
    case chorus(rateHz: Double, depth: Double, wet: Double)
    case flanger(rateHz: Double, delaySeconds: Double, depthSeconds: Double, feedback: Double, wet: Double)
    case phaser(rateHz: Double, minimumHz: Double, maximumHz: Double, stages: Int, feedback: Double, wet: Double)
    case stereoWidth(Double)
}
