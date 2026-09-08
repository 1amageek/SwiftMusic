/// Wire-safe metadata for a mapped performance control.
public struct PerformanceControlMetadata: Codable, Sendable, Equatable, Hashable {
    public let modelID: String
    public let controlID: String
    public let label: String
    public let domain: PerformanceControlDomain
    public let value: PerformanceControlValue

    public init(
        modelID: String,
        controlID: String,
        label: String,
        domain: PerformanceControlDomain,
        value: PerformanceControlValue
    ) {
        self.modelID = modelID
        self.controlID = controlID
        self.label = label
        self.domain = domain
        self.value = value
    }

    /// Validates a decoded complete control catalog before it crosses a worker boundary.
    /// Key paths are intentionally absent here; the owning MainActor model validates them
    /// through `PerformanceControlSet` before producing this wire representation.
    public static func validate(_ metadata: [Self]) throws {
        guard metadata.count <= 1_024 else {
            throw PerformanceControlError.invalidMapping("too many controls")
        }
        var modelID: String?
        var identifiers = Set<String>()
        var hasBeatsPerMinute = false
        for control in metadata {
            guard !control.modelID.isEmpty else {
                throw PerformanceControlError.invalidModelID
            }
            if let modelID, modelID != control.modelID {
                throw PerformanceControlError.invalidMapping("multiple performance model IDs")
            }
            modelID = control.modelID
            guard !control.controlID.isEmpty else {
                throw PerformanceControlError.invalidControlID
            }
            guard identifiers.insert(control.controlID).inserted else {
                throw PerformanceControlError.duplicateControlID(control.controlID)
            }
            switch (control.domain, control.value) {
            case let (.double(range, role), .double(value)):
                try validate(range: range, id: control.controlID)
                try validate(value: value, range: range, id: control.controlID)
                if role == .beatsPerMinute {
                    guard !hasBeatsPerMinute else {
                        throw PerformanceControlError.multipleBeatsPerMinuteControls
                    }
                    guard range.lowerBound > 0, value > 0 else {
                        throw PerformanceControlError.valueOutOfRange(control.controlID)
                    }
                    hasBeatsPerMinute = true
                }
            case let (.position(xRange, depthRange), .position(value)):
                try validate(range: xRange, id: "\(control.controlID).x")
                try validate(range: depthRange, id: "\(control.controlID).depth")
                guard xRange.lowerBound >= -1, xRange.upperBound <= 1,
                      depthRange.lowerBound >= 0, depthRange.upperBound <= 1 else {
                    throw PerformanceControlError.invalidRange(control.controlID)
                }
                try validate(value: value.x, range: xRange, id: "\(control.controlID).x")
                try validate(value: value.depth, range: depthRange, id: "\(control.controlID).depth")
            case (.double, .position), (.position, .double):
                throw PerformanceControlError.valueTypeMismatch(control.controlID)
            }
        }
    }

    private static func validate(range: ClosedRange<Double>, id: String) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound <= range.upperBound else {
            throw PerformanceControlError.invalidRange(id)
        }
    }

    private static func validate(value: Double, range: ClosedRange<Double>, id: String) throws {
        guard value.isFinite else { throw PerformanceControlError.nonFiniteValue(id) }
        guard range.contains(value) else { throw PerformanceControlError.valueOutOfRange(id) }
    }

}
