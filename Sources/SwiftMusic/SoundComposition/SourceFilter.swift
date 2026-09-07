/// A per-voice filter; each event owns its cutoff frequency.
public struct SourceFilter: Sendable, Equatable {
    public let kind: FilterKind
    public let resonanceQ: Double
    public let slope: FilterSlope

    internal init(kind: FilterKind, resonanceQ: Double, slope: FilterSlope) throws {
        guard kind != .notch else {
            throw SoundCompilationError.invalidParameter("Notch source filter is unsupported")
        }
        guard resonanceQ.isFinite, (0.1...32).contains(resonanceQ) else {
            throw SoundCompilationError.invalidParameter("Source filter Q must be finite and in 0.1...32")
        }
        self.kind = kind
        self.resonanceQ = resonanceQ
        self.slope = slope
    }
}
