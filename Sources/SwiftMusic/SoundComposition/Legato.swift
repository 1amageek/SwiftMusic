/// Scoped event connection with an exact nonnegative overlap.
public struct Legato: Sendable, Equatable, Hashable {
    public let overlap: MusicalTime

    public init(overlap: MusicalTime = .zero) {
        self.overlap = overlap
    }
}
