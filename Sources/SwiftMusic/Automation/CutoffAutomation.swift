/// Maps a normalized automation signal to a source-filter cutoff.
public struct CutoffAutomation: Sendable, Equatable, Hashable {
    public let signal: AutomationSignal
    public let from: Frequency
    public let to: Frequency

    public init(_ signal: AutomationSignal, from: Frequency, to: Frequency) throws {
        guard (to.hertz - from.hertz).isFinite else { throw AutomationError.invalidEndpoint }
        self.signal = signal
        self.from = from
        self.to = to
    }

    public func value(at phase: Double) throws -> Double {
        let normalized = try signal.value(at: phase)
        let result = normalized == 1 ? to.hertz : from.hertz + normalized * (to.hertz - from.hertz)
        guard result.isFinite else { throw AutomationError.nonfiniteMappedValue }
        return result
    }

    internal var synchronizedPeriod: MusicalTime? { signal.synchronizedPeriod }
}
