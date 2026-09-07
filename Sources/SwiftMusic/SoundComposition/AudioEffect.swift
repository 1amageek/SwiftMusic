public enum AudioEffect: Sendable, Equatable, Hashable {
    public static func equalizer(frequency: Frequency, gain: Decibels, q: Double) -> Self {
        .equalizer(frequencyHz: frequency.hertz, gainDecibels: gain.value, q: q)
    }

    public static func compressor(threshold: Decibels, ratio: Double) -> Self {
        .compressor(thresholdDecibels: threshold.value, ratio: ratio)
    }

    case equalizer(frequencyHz: Double, gainDecibels: Double, q: Double)
    case filter(kind: FilterKind, cutoffHz: Double, resonance: Double)
    case compressor(thresholdDecibels: Double, ratio: Double)
    case saturation(drive: Double)
    case distortion(drive: Double)
    case delay(time: MusicalTime, feedback: Double, wet: Double)
    case reverb(roomSize: Double, wet: Double)
    case chorus(rateHz: Double, depth: Double, wet: Double)
}
