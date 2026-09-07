public enum AudioEffect: Sendable, Equatable, Hashable {
    case equalizer(frequencyHz: Double, gainDecibels: Double, q: Double)
    case filter(kind: FilterKind, cutoffHz: Double, resonance: Double)
    case compressor(thresholdDecibels: Double, ratio: Double)
    case distortion(drive: Double)
    case delay(time: MusicalTime, feedback: Double, wet: Double)
    case reverb(roomSize: Double, wet: Double)
    case chorus(rateHz: Double, depth: Double, wet: Double)
}
