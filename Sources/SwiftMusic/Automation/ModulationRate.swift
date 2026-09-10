/// The clock used by a continuous automation signal.
public enum ModulationRate: Sendable, Equatable, Hashable {
    case hertz(Frequency)
    case synchronized(period: MusicalTime)
}
