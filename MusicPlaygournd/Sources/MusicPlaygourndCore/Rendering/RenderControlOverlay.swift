import Foundation

internal struct RenderControlOverlay: Sendable {
    enum Value: Sendable {
        case scalar(Double)
        case bypassed
    }

    var sourceGain: [Int: Double] = [:]
    var sourcePan: [Int: Double] = [:]
    var sourcePitch: [Int: Double] = [:]
    var sourceCutoff: [Int: Double] = [:]
    var nodeGain: [Int: Double] = [:]
    var nodePan: [Int: Double] = [:]
    var trackLevel: [Int: Double] = [:]
    var trackMute: [Int: Bool] = [:]
    var trackPan: [Int: Value] = [:]

    static func make(
        overrides: [LiveControlOverride],
        catalog: LiveControlCatalog,
        revision: UInt64
    ) throws -> Self {
        var result = Self()
        var addresses = Set<LiveControlAddress>()
        for override in overrides {
            let address = override.address
            guard address.revision == revision else {
                throw LiveControlError.staleRevision(expected: revision, actual: address.revision)
            }
            guard addresses.insert(address).inserted else {
                throw LiveControlError.duplicateAddress(address)
            }
            guard catalog.descriptor(for: address) != nil else {
                throw LiveControlError.unknownAddress(address)
            }
            switch address.target {
            case .master:
                throw LiveControlError.unsupportedAddress(address)
            case .source(let id):
                switch address.parameter {
                case .gain:
                    result.sourceGain[id] = try number(override.value, address: address, valid: { $0.isFinite && $0 >= 0 })
                case .pan:
                    result.sourcePan[id] = try number(override.value, address: address, valid: { $0.isFinite && (-1...1).contains($0) })
                case .pitchOffsetSemitones:
                    result.sourcePitch[id] = try number(override.value, address: address, valid: { $0.isFinite })
                case .cutoffHz:
                    result.sourceCutoff[id] = try number(override.value, address: address, valid: { $0.isFinite && (20..<22_050).contains($0) })
                default:
                    throw LiveControlError.unsupportedAddress(address)
                }
            case .renderNode(let id):
                switch address.parameter {
                case .gain:
                    result.nodeGain[id] = try number(override.value, address: address, valid: { $0.isFinite && $0 >= 0 })
                case .pan:
                    result.nodePan[id] = try number(override.value, address: address, valid: { $0.isFinite && (-1...1).contains($0) })
                default:
                    throw LiveControlError.unsupportedAddress(address)
                }
            case .track(let id):
                switch address.parameter {
                case .trackMute:
                    result.trackMute[id] = try number(override.value, address: address, valid: { $0 == 0 || $0 == 1 }) == 1
                case .trackLevel:
                    result.trackLevel[id] = try number(override.value, address: address, valid: { $0.isFinite && $0 >= 0 })
                case .trackPan:
                    switch override.value {
                    case .bypassed:
                        result.trackPan[id] = .bypassed
                    case .number(let value):
                        guard value.isFinite, (-1...1).contains(value) else {
                            throw LiveControlError.invalidValue(address)
                        }
                        result.trackPan[id] = .scalar(value)
                    }
                default:
                    throw LiveControlError.unsupportedAddress(address)
                }
            }
        }
        return result
    }

    private static func number(
        _ value: LiveControlValue,
        address: LiveControlAddress,
        valid: (Double) -> Bool
    ) throws -> Double {
        guard case .number(let value) = value, valid(value) else {
            throw LiveControlError.invalidValue(address)
        }
        return value
    }

    func effectiveTrackPan(_ id: Int, baseline: Double?) -> Double? {
        guard let value = trackPan[id] else { return baseline }
        switch value {
        case .scalar(let value): return value
        case .bypassed: return nil
        }
    }
}
