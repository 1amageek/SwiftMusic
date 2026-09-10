/// One normalized point in an `AutomationCurve`.
public struct AutomationPoint: Sendable, Equatable, Hashable {
    public let position: MusicalTime
    public let value: Double
    public let interpolationToNext: AutomationInterpolation

    public init(
        position: MusicalTime,
        value: Double,
        interpolationToNext: AutomationInterpolation
    ) {
        self.position = position
        self.value = value
        self.interpolationToNext = interpolationToNext
    }
}
