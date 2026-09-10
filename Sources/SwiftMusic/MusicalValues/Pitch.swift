/// A transport-neutral MIDI pitch in the valid seven-bit range.
public struct Pitch: Sendable, Hashable, Comparable {
    public let midiNote: UInt8

    public static let middleC = Pitch(uncheckedMidiNote: 60)

    public init(midiNote: UInt8) throws {
        guard midiNote <= 127 else {
            throw PitchError.outOfRange(midiNote)
        }
        self.midiNote = midiNote
    }

    public static func < (lhs: Pitch, rhs: Pitch) -> Bool {
        lhs.midiNote < rhs.midiNote
    }

    internal init(uncheckedMidiNote: UInt8) {
        self.midiNote = uncheckedMidiNote
    }
}
