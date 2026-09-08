import AVFoundation
import Foundation

internal enum AudioUnitCatalog {
    internal static let maximumComponentCount = 256

    internal static func discover() throws -> [HostedAudioUnitDescriptor] {
        let description = AudioComponentDescription(
            componentType: OSType(kAudioUnitType_Effect),
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let components = AVAudioUnitComponentManager.shared().components(matching: description)
        guard components.count <= maximumComponentCount else {
            throw HostedAudioUnitError.tooManyComponents
        }

        var descriptors: [HostedAudioUnitDescriptor] = []
        descriptors.reserveCapacity(components.count)
        for component in components {
            let nativeDescription = component.audioComponentDescription
            let id = try HostedAudioUnitID(
                componentType: UInt32(nativeDescription.componentType),
                componentSubType: UInt32(nativeDescription.componentSubType),
                componentManufacturer: UInt32(nativeDescription.componentManufacturer)
            )
            guard let version = UInt32(exactly: component.version) else {
                throw HostedAudioUnitError.invalidDescriptor
            }
            descriptors.append(try HostedAudioUnitDescriptor(
                id: id,
                name: component.name,
                manufacturerName: component.manufacturerName,
                version: version
            ))
        }
        return try validated(descriptors)
    }

    internal static func validated(_ descriptors: [HostedAudioUnitDescriptor]) throws -> [HostedAudioUnitDescriptor] {
        guard descriptors.count <= maximumComponentCount else {
            throw HostedAudioUnitError.tooManyComponents
        }
        var identities = Set<HostedAudioUnitID>()
        identities.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            guard identities.insert(descriptor.id).inserted else {
                throw HostedAudioUnitError.duplicateComponent
            }
        }
        return descriptors.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.manufacturerName != rhs.manufacturerName { return lhs.manufacturerName < rhs.manufacturerName }
            if lhs.id.componentType != rhs.id.componentType { return lhs.id.componentType < rhs.id.componentType }
            if lhs.id.componentSubType != rhs.id.componentSubType { return lhs.id.componentSubType < rhs.id.componentSubType }
            return lhs.id.componentManufacturer < rhs.id.componentManufacturer
        }
    }
}
