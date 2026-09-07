/// A normalized signal that can be mapped onto one domain parameter.
public enum AutomationSignal: Sendable, Equatable, Hashable {
    case lfo(LFO)
    case steps(StepAutomation)
    case curve(AutomationCurve)

    /// Evaluates the signal at a normalized phase.
    public func value(at phase: Double) throws -> Double {
        switch self {
        case .lfo(let lfo): return try lfo.value(at: phase + lfo.phase)
        case .steps(let steps): return try steps.value(at: phase)
        case .curve(let curve): return try curve.value(at: phase)
        }
    }

    /// The exact musical period, when this signal is driven by a musical clock.
    internal var synchronizedPeriod: MusicalTime? {
        switch self {
        case .lfo(let lfo):
            if case .synchronized(let period) = lfo.rate { return period }
            return nil
        case .steps(let steps): return steps.cycle
        case .curve(let curve): return curve.cycle
        }
    }
}
