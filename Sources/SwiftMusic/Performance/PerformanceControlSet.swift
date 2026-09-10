import Observation

/// A complete, MainActor-owned set of typed performance-control mappings.
@MainActor
public struct PerformanceControlSet<Model: AnyObject & Observable & Sendable> {
    public let controls: [PerformanceControlDescriptor<Model>]

    public init(_ controls: [PerformanceControlDescriptor<Model>]) throws {
        guard controls.count <= 1_024 else {
            throw PerformanceControlError.invalidMapping("too many controls")
        }

        var identifiers = Set<String>()
        var keyPaths = Set<AnyKeyPath>()
        var hasBeatsPerMinute = false
        for control in controls {
            let id: String
            let keyPath: AnyKeyPath
            switch control {
            case .double(let controlID, _, let range, let role, let mappedKeyPath):
                id = controlID
                keyPath = mappedKeyPath
                try Self.validateIdentifier(controlID, kind: .control)
                try Self.validate(range: range, id: controlID)
                if role == .beatsPerMinute {
                    guard !hasBeatsPerMinute else {
                        throw PerformanceControlError.multipleBeatsPerMinuteControls
                    }
                    guard range.lowerBound > 0 else {
                        throw PerformanceControlError.invalidRange(controlID)
                    }
                    hasBeatsPerMinute = true
                }
            case .position(let controlID, _, let xRange, let depthRange, let mappedKeyPath):
                id = controlID
                keyPath = mappedKeyPath
                try Self.validateIdentifier(controlID, kind: .control)
                try Self.validate(range: xRange, id: "\(controlID).x")
                try Self.validate(range: depthRange, id: "\(controlID).depth")
                guard xRange.lowerBound >= -1, xRange.upperBound <= 1,
                      depthRange.lowerBound >= 0, depthRange.upperBound <= 1 else {
                    throw PerformanceControlError.invalidRange(controlID)
                }
            }
            guard identifiers.insert(id).inserted else {
                throw PerformanceControlError.duplicateControlID(id)
            }
            guard keyPaths.insert(keyPath).inserted else {
                throw PerformanceControlError.invalidMapping("multiple control IDs target one key path")
            }
        }
        self.controls = controls
    }

    public var count: Int { controls.count }

    internal func validate(modelID: String) throws {
        try Self.validateIdentifier(modelID, kind: .model)
    }

    public func metadata(modelID: String, for model: Model) throws -> [PerformanceControlMetadata] {
        try validate(modelID: modelID)
        return try controls.map { try metadata(for: $0, modelID: modelID, model: model) }
    }

    public func apply(
        values: [String: PerformanceControlValue],
        to model: Model
    ) throws {
        let mutations = try validatedMutations(values: values)
        // All key paths are written only after the complete candidate set has passed admission.
        for mutation in mutations {
            switch mutation {
            case .double(let keyPath, let value): model[keyPath: keyPath] = value
            case .position(let keyPath, let value): model[keyPath: keyPath] = value
            }
        }
    }

    public func validate(values: [String: PerformanceControlValue]) throws {
        _ = try validatedMutations(values: values)
    }

    private enum Mutation {
        case double(ReferenceWritableKeyPath<Model, Double>, Double)
        case position(ReferenceWritableKeyPath<Model, SpatialPosition>, SpatialPosition)
    }

    private func validatedMutations(
        values: [String: PerformanceControlValue]
    ) throws -> [Mutation] {
        guard values.count == controls.count else {
            let known = Set(controls.map(Self.identifier))
            if let missing = known.subtracting(values.keys).sorted().first {
                throw PerformanceControlError.missingValue(missing)
            }
            if let unknown = Set(values.keys).subtracting(known).sorted().first {
                throw PerformanceControlError.unknownControl(unknown)
            }
            throw PerformanceControlError.invalidMapping("control set is incomplete")
        }

        var mutations: [Mutation] = []
        mutations.reserveCapacity(controls.count)
        for control in controls {
            switch control {
            case .double(let id, _, let range, let role, let keyPath):
                guard let value = values[id] else { throw PerformanceControlError.missingValue(id) }
                guard case .double(let candidate) = value else {
                    throw PerformanceControlError.valueTypeMismatch(id)
                }
                try Self.validate(candidate: candidate, range: range, id: id)
                if role == .beatsPerMinute, candidate <= 0 {
                    throw PerformanceControlError.valueOutOfRange(id)
                }
                mutations.append(.double(keyPath, candidate))
            case .position(let id, _, let xRange, let depthRange, let keyPath):
                guard let value = values[id] else { throw PerformanceControlError.missingValue(id) }
                guard case .position(let candidate) = value else {
                    throw PerformanceControlError.valueTypeMismatch(id)
                }
                try Self.validate(candidate: candidate.x, range: xRange, id: "\(id).x")
                try Self.validate(candidate: candidate.depth, range: depthRange, id: "\(id).depth")
                mutations.append(.position(keyPath, candidate))
            }
        }
        return mutations
    }

    private func metadata(
        for control: PerformanceControlDescriptor<Model>,
        modelID: String,
        model: Model
    ) throws -> PerformanceControlMetadata {
        switch control {
        case .double(let id, let label, let range, let role, let keyPath):
            let value = model[keyPath: keyPath]
            try Self.validate(candidate: value, range: range, id: id)
            if role == .beatsPerMinute, value <= 0 {
                throw PerformanceControlError.valueOutOfRange(id)
            }
            return PerformanceControlMetadata(
                modelID: modelID,
                controlID: id,
                label: label ?? id,
                domain: .double(range: range, role: role),
                value: .double(value)
            )
        case .position(let id, let label, let xRange, let depthRange, let keyPath):
            let value = model[keyPath: keyPath]
            try Self.validate(candidate: value.x, range: xRange, id: "\(id).x")
            try Self.validate(candidate: value.depth, range: depthRange, id: "\(id).depth")
            return PerformanceControlMetadata(
                modelID: modelID,
                controlID: id,
                label: label ?? id,
                domain: .position(xRange: xRange, depthRange: depthRange),
                value: .position(value)
            )
        }
    }

    private static func identifier(_ control: PerformanceControlDescriptor<Model>) -> String {
        switch control {
        case .double(let id, _, _, _, _), .position(let id, _, _, _, _): id
        }
    }

    private enum IdentifierKind { case model, control }

    private static func validateIdentifier(_ value: String, kind: IdentifierKind) throws {
        guard !value.isEmpty, !value.utf8.isEmpty else {
            throw kind == .model ? PerformanceControlError.invalidModelID : .invalidControlID
        }
    }

    private static func validate(range: ClosedRange<Double>, id: String) throws {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound <= range.upperBound else {
            throw PerformanceControlError.invalidRange(id)
        }
    }

    private static func validate(candidate: Double, range: ClosedRange<Double>, id: String) throws {
        guard candidate.isFinite else { throw PerformanceControlError.nonFiniteValue(id) }
        guard range.contains(candidate) else { throw PerformanceControlError.valueOutOfRange(id) }
    }
}
