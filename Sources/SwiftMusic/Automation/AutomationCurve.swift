import Foundation

/// A bounded cyclic normalized automation curve.
public struct AutomationCurve: Sendable, Equatable, Hashable {
    public let points: [AutomationPoint]
    public let cycle: MusicalTime

    public init(points: [AutomationPoint], cycle: MusicalTime) throws {
        guard !points.isEmpty else { throw AutomationError.emptyValues }
        guard points.count <= 1_024 else {
            throw AutomationError.tooManyValues(limit: 1_024)
        }
        guard cycle > .zero else { throw AutomationError.invalidCycle }
        guard points[0].position == .zero else {
            throw AutomationError.invalidPosition(index: 0)
        }
        let cycleValue = Double(cycle.numerator) / Double(cycle.denominator)
        guard cycleValue.isFinite, cycleValue > 0 else {
            throw AutomationError.timingOverflow
        }
        var previousPositionValue: Double?
        for (index, point) in points.enumerated() {
            guard point.value.isFinite, (0...1).contains(point.value) else {
                throw AutomationError.invalidValue(index: index)
            }
            guard point.position < cycle else {
                throw AutomationError.invalidPosition(index: index)
            }
            if index > 0, !(points[index - 1].position < point.position) {
                throw AutomationError.invalidPosition(index: index)
            }
            let positionValue = Double(point.position.numerator) / Double(point.position.denominator)
            guard positionValue.isFinite, positionValue < cycleValue else {
                throw AutomationError.timingOverflow
            }
            if let previousPositionValue, !(previousPositionValue < positionValue) {
                throw AutomationError.timingOverflow
            }
            previousPositionValue = positionValue
        }
        self.points = points
        self.cycle = cycle
    }

    /// Evaluates the curve at a normalized phase, including its wrapped final segment.
    public func value(at phase: Double) throws -> Double {
        let normalized = try LFO.normalized(phase)
        let cycleValue = Double(cycle.numerator) / Double(cycle.denominator)
        guard cycleValue.isFinite, cycleValue > 0 else {
            throw AutomationError.timingOverflow
        }
        let time = normalized * cycleValue
        func position(_ point: AutomationPoint) -> Double {
            Double(point.position.numerator) / Double(point.position.denominator)
        }
        var lower = 0
        var upper = points.count
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if position(points[middle]) <= time { lower = middle }
            else { upper = middle }
        }
        let index = lower
        let point = points[index]
        let start = position(point)
        let end: Double
        let endValue: Double
        if index + 1 < points.count {
            end = position(points[index + 1])
            endValue = points[index + 1].value
        } else {
            end = cycleValue
            endValue = points[0].value
        }
        guard end > start else { throw AutomationError.timingOverflow }
        let t = min(1, max(0, (time - start) / (end - start)))
        let progress: Double
        switch point.interpolationToNext {
        case .hold:
            progress = 0
        case .linear:
            progress = t
        case .smoothstep:
            progress = t * t * (3 - 2 * t)
        }
        let result = point.value + (endValue - point.value) * progress
        guard result.isFinite, (0...1).contains(result) else {
            throw AutomationError.nonfiniteMappedValue
        }
        return result
    }
}
