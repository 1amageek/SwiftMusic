import Foundation

public enum LiveControlParameter: Codable, Sendable, Equatable, Hashable {
    case gain
    case pan
    case pitchOffsetSemitones
    case cutoffHz
    case trackLevel
    case trackMute
    case trackPan
    case playbackRate
    case lowPassCutoff
    case delayMix
    case reverbMix
}
