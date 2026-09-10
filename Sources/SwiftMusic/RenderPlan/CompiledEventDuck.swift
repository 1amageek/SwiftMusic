/// A resolved event-triggered attenuation rule in the final event order.
public struct CompiledEventDuck: Sendable, Equatable, Hashable {
    public let triggerEventIndex: Int
    public let targetBus: String
    public let depthDecibels: Double
    public let attackSeconds: Double
    public let recoverySeconds: Double

    public init(
        triggerEventIndex: Int,
        targetBus: String,
        depthDecibels: Double,
        attackSeconds: Double,
        recoverySeconds: Double
    ) {
        self.triggerEventIndex = triggerEventIndex
        self.targetBus = targetBus
        self.depthDecibels = depthDecibels
        self.attackSeconds = attackSeconds
        self.recoverySeconds = recoverySeconds
    }
}

internal struct _PendingEventDuck: Sendable, Equatable {
    let targetBus: String
    let depthDecibels: Double
    let attackSeconds: Double
    let recoverySeconds: Double
}
