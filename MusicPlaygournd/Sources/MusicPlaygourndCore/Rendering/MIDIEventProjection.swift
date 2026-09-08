/// Explicit capability for exporting a rendered event as a MIDI note.
public enum MIDIEventProjection: Codable, Sendable, Equatable {
    case none
    case note(Int)
    case unsupported(MIDIProjectionLimitation)
}

public enum MIDIProjectionLimitation: String, Codable, Sendable, Equatable {
    case fractionalPitch
    case timeVaryingPitch
    case legacyMetadataMissing
    case outOfRange
}
