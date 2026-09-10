/// A bounded normalized step sequence over one musical cycle.
public struct StepAutomation: Sendable, Equatable, Hashable {
    public let values: [Double]
    public let cycle: MusicalTime

    public init(values: [Double], cycle: MusicalTime) throws {
        guard !values.isEmpty else { throw AutomationError.emptyValues }
        guard values.count <= 1_024 else {
            throw AutomationError.tooManyValues(limit: 1_024)
        }
        guard cycle > .zero else { throw AutomationError.invalidCycle }
        for (index, value) in values.enumerated() {
            guard value.isFinite, (0...1).contains(value) else {
                throw AutomationError.invalidValue(index: index)
            }
        }
        self.values = values
        self.cycle = cycle
    }

    /// Evaluates the step sequence at a normalized phase.
    public func value(at phase: Double) throws -> Double {
        let normalized = try LFO.normalized(phase)
        let rawIndex = Int((normalized * Double(values.count)).rounded(.down))
        return values[min(values.count - 1, max(0, rawIndex))]
    }
}
