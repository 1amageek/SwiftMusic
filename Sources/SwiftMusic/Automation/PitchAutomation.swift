/// Maps a normalized automation signal to an additive semitone offset.
public struct PitchAutomation: Sendable, Equatable, Hashable {
    public let signal: AutomationSignal
    public let from: Semitones
    public let to: Semitones

    public init(_ signal: AutomationSignal, from: Semitones, to: Semitones) throws {
        guard (to.value - from.value).isFinite else { throw AutomationError.invalidEndpoint }
        self.signal = signal
        self.from = from
        self.to = to
    }

    public func value(at phase: Double) throws -> Double {
        let normalized = try signal.value(at: phase)
        let result = normalized == 1 ? to.value : from.value + normalized * (to.value - from.value)
        guard result.isFinite else { throw AutomationError.nonfiniteMappedValue }
        return result
    }

    internal var synchronizedPeriod: MusicalTime? { signal.synchronizedPeriod }
}
