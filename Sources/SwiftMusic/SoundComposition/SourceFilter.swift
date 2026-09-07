/// A per-voice filter; each event owns its cutoff frequency.
public struct SourceFilter: Sendable, Equatable {
    public let kind: FilterKind
    public let resonanceQ: Double
    public let slope: FilterSlope

    internal init(resonanceQ: Double, slope: FilterSlope) throws {
        guard resonanceQ.isFinite, resonanceQ > 0 else {
            throw SoundCompilationError.invalidParameter("Source filter Q must be finite and positive")
        }
        self.kind = .lowPass
        self.resonanceQ = resonanceQ
        self.slope = slope
    }
}
