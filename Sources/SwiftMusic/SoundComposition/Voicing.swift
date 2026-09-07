/// Checked octave offsets assigned in declared harmony-voice order.
public struct Voicing: Sendable, Equatable, Hashable {
    public let octaveOffsets: [Int]

    /// Creates a bounded voicing and checks every octave-to-semitone conversion.
    public init(octaveOffsets: [Int]) throws {
        guard (1...16).contains(octaveOffsets.count) else {
            throw HarmonyError.invalidVoicing
        }
        for offset in octaveOffsets {
            let (_, overflowed) = offset.multipliedReportingOverflow(by: 12)
            guard !overflowed else {
                throw HarmonyError.invalidVoicing
            }
        }
        self.octaveOffsets = octaveOffsets
    }
}
