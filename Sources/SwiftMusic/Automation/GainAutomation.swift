/// Maps a normalized automation signal to a nonnegative gain.
public struct GainAutomation: Sendable, Equatable, Hashable {
    public let signal: AutomationSignal
    public let from: Double
    public let to: Double

    public init(_ signal: AutomationSignal, from: Double, to: Double) throws {
        guard from.isFinite, from >= 0, to.isFinite, to >= 0 else {
            throw AutomationError.invalidEndpoint
        }
        self.signal = signal
        self.from = from
        self.to = to
    }

    public func value(at phase: Double) throws -> Double {
        let normalized = try signal.value(at: phase)
        let result = normalized == 1 ? to : from + normalized * (to - from)
        guard result.isFinite else { throw AutomationError.nonfiniteMappedValue }
        return result
    }

    internal var synchronizedPeriod: MusicalTime? { signal.synchronizedPeriod }
}
