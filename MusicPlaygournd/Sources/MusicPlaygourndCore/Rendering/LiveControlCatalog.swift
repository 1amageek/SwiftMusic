import Foundation
import SwiftMusic

public struct LiveControlCatalog: Codable, Sendable, Equatable, Hashable {
    public let descriptors: [LiveControlDescriptor]

    public init(descriptors: [LiveControlDescriptor]) throws {
        var addresses = Set<LiveControlAddress>()
        for descriptor in descriptors {
            guard !descriptor.label.isEmpty else {
                throw LiveControlError.invalidCatalog("control labels cannot be empty")
            }
            if case .scalar(let value) = descriptor.baseline, !value.isFinite {
                throw LiveControlError.invalidCatalog("scalar baselines must be finite")
            }
            if let presentation = descriptor.presentation {
                let standard = try LiveControlPresentation.suggested(for: descriptor.address.parameter)
                guard presentation.unit == standard.unit, presentation.scale == standard.scale,
                      presentation.minimum <= standard.minimum, presentation.maximum >= standard.maximum else {
                    throw LiveControlError.invalidCatalog("Presentation must preserve its parameter unit, scale and standard span")
                }
                if case .scalar(let value) = descriptor.baseline,
                   !(presentation.minimum...presentation.maximum).contains(value) {
                    throw LiveControlError.invalidCatalog("Presentation excludes its scalar baseline")
                }
            }
            guard addresses.insert(descriptor.address).inserted else {
                throw LiveControlError.duplicateAddress(descriptor.address)
            }
        }
        self.descriptors = descriptors
    }

    /// Validates a score override through the same admission path used by rendering.
    public func validate(value: LiveControlValue, for address: LiveControlAddress) throws {
        _ = try RenderControlOverlay.make(overrides: [.init(address: address, value: value)],
            catalog: self, revision: address.revision)
    }

    public func descriptor(for address: LiveControlAddress) -> LiveControlDescriptor? {
        descriptors.first { $0.address == address }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(descriptors: values.decode([LiveControlDescriptor].self, forKey: .descriptors))
    }

    internal init(sound: CompiledSound, revision: UInt64) throws {
        var descriptors: [LiveControlDescriptor] = []
        descriptors.reserveCapacity(sound.sources.count * 4 + sound.renderNodes.count + sound.tracks.count * 3)

        func address(_ target: LiveControlTarget, _ parameter: LiveControlParameter) -> LiveControlAddress {
            LiveControlAddress(revision: revision, target: target, parameter: parameter)
        }

        for source in sound.sources {
            let target = LiveControlTarget.source(source.id)
            descriptors.append(.init(address: address(target, .gain), label: "Source \(source.id) Gain", baseline: .scalar(1)))
            descriptors.append(.init(address: address(target, .pan), label: "Source \(source.id) Pan", baseline: .bypassed))
            if Self.supportsPitch(source.kind) {
                descriptors.append(.init(address: address(target, .pitchOffsetSemitones),
                                         label: "Source \(source.id) Pitch",
                                         baseline: source.pitchAutomation == nil ? .scalar(0) : .automation))
            }
            if source.filter != nil,
               let event = sound.events.first(where: { $0.sourceID == source.id }),
               let cutoff = event.cutoffHz {
                guard cutoff.isFinite else {
                    throw LiveControlError.invalidCatalog("source cutoff baseline is non-finite")
                }
                descriptors.append(.init(address: address(target, .cutoffHz),
                                         label: "Source \(source.id) Cutoff",
                                         baseline: source.cutoffAutomation != nil || sound.events.contains {
                                             $0.sourceID == source.id && $0.cutoffHz != cutoff
                                         } ? .automation : .scalar(cutoff)))
            }
        }

        for (index, node) in sound.renderNodes.enumerated() {
            let target = LiveControlTarget.renderNode(index)
            switch node {
            case .gain(_, let value):
                descriptors.append(.init(address: address(target, .gain), label: "Render Node \(index) Gain", baseline: .scalar(value)))
            case .gainAutomation:
                descriptors.append(.init(address: address(target, .gain), label: "Render Node \(index) Gain", baseline: .automation))
            case .pan(_, let value):
                descriptors.append(.init(address: address(target, .pan), label: "Render Node \(index) Pan", baseline: .scalar(value)))
            case .panAutomation:
                descriptors.append(.init(address: address(target, .pan), label: "Render Node \(index) Pan", baseline: .automation))
            default:
                break
            }
        }

        for track in sound.tracks {
            let target = LiveControlTarget.track(track.id)
            descriptors.append(.init(address: address(target, .trackMute), label: track.name.isEmpty ? "Track \(track.id)" : track.name, baseline: .scalar(track.isMuted ? 1 : 0)))
            descriptors.append(.init(address: address(target, .trackLevel), label: "Track \(track.id) Level", baseline: .scalar(track.level)))
            descriptors.append(.init(address: address(target, .trackPan), label: "Track \(track.id) Pan",
                                     baseline: track.pan.map(LiveControlBaseline.scalar) ?? .bypassed))
        }

        descriptors = try descriptors.map { descriptor in
            if descriptor.address.parameter == .trackMute { return descriptor }
            var values: [Double] = []
            if case .scalar(let value) = descriptor.baseline { values.append(value) }
            switch descriptor.address.target {
            case .source(let id):
                let source = sound.sources[id]
                if descriptor.address.parameter == .pitchOffsetSemitones, let automation = source.pitchAutomation {
                    values += [automation.from.value, automation.to.value]
                }
                if descriptor.address.parameter == .cutoffHz {
                    if let automation = source.cutoffAutomation { values += [automation.from.hertz, automation.to.hertz] }
                    for event in sound.events where event.sourceID == id {
                        if let cutoff = event.cutoffHz { values.append(cutoff) }
                    }
                }
            case .renderNode(let id):
                switch sound.renderNodes[id] {
                case .gainAutomation(_, let automation): values += [automation.from, automation.to]
                case .panAutomation(_, let automation): values += [automation.from, automation.to]
                default: break
                }
            default: break
            }
            return LiveControlDescriptor(address: descriptor.address, label: descriptor.label,
                baseline: descriptor.baseline,
                presentation: try .suggested(for: descriptor.address.parameter, including: values))
        }

        try self.init(descriptors: descriptors)
    }

    private static func supportsPitch(_ kind: SourceKind) -> Bool {
        switch kind {
        case .synthesizer(.noise), .synthesizer(.coloredNoise), .sample: false
        case .synthesizer, .fileSample, .sampleBank: true
        }
    }
}
