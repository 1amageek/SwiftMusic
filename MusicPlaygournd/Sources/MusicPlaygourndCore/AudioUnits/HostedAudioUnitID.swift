import AVFoundation
import Foundation

public struct HostedAudioUnitID: Codable, Hashable, Sendable {
    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32

    public init(
        componentType: UInt32,
        componentSubType: UInt32,
        componentManufacturer: UInt32
    ) throws {
        guard componentType == UInt32(kAudioUnitType_Effect) else {
            throw HostedAudioUnitError.unsupportedComponentType(componentType)
        }
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
    }

    public init(componentDescription: AudioComponentDescription) throws {
        guard componentDescription.componentFlags == 0,
              componentDescription.componentFlagsMask == 0
        else {
            throw HostedAudioUnitError.invalidDescriptor
        }
        try self.init(
            componentType: UInt32(componentDescription.componentType),
            componentSubType: UInt32(componentDescription.componentSubType),
            componentManufacturer: UInt32(componentDescription.componentManufacturer)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            componentType: container.decode(UInt32.self, forKey: .componentType),
            componentSubType: container.decode(UInt32.self, forKey: .componentSubType),
            componentManufacturer: container.decode(UInt32.self, forKey: .componentManufacturer)
        )
    }

    public var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: OSType(componentType),
            componentSubType: OSType(componentSubType),
            componentManufacturer: OSType(componentManufacturer),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case componentType
        case componentSubType
        case componentManufacturer
    }
}
