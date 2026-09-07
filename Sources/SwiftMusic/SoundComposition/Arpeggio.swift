/// A bounded exact-time arpeggiation descriptor.
public struct Arpeggio: Sendable, Equatable, Hashable {
    public let order: ArpeggioOrder
    public let step: MusicalTime

    /// Creates an arpeggio with a strictly positive inter-voice step.
    public init(order: ArpeggioOrder, step: MusicalTime) throws {
        guard step > .zero else {
            throw HarmonyError.invalidArpeggio
        }
        self.order = order
        self.step = step
    }
}
