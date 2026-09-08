import AVFoundation
import Foundation
import Testing
@testable import MusicPlaygourndCore

struct AudioUnitCatalogTests {
    @Test func identifierRoundTripsAndRejectsUnsupportedKinds() throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_HighPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let id = try HostedAudioUnitID(componentDescription: description)
        #expect(id.componentDescription.componentType == description.componentType)
        #expect(id.componentDescription.componentSubType == description.componentSubType)
        #expect(id.componentDescription.componentManufacturer == description.componentManufacturer)
        #expect(id.componentDescription.componentFlags == 0)
        #expect(id.componentDescription.componentFlagsMask == 0)

        #expect(throws: HostedAudioUnitError.unsupportedComponentType(UInt32(kAudioUnitType_Generator))) {
            try HostedAudioUnitID(
                componentType: UInt32(kAudioUnitType_Generator),
                componentSubType: 0,
                componentManufacturer: 0
            )
        }
        let invalidFlags = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 1,
            componentFlagsMask: 0
        )
        #expect(throws: HostedAudioUnitError.invalidDescriptor) {
            try HostedAudioUnitID(componentDescription: invalidFlags)
        }
    }

    @Test func descriptorsAreValidatedSortedAndBounded() throws {
        let firstID = try HostedAudioUnitID(componentType: UInt32(kAudioUnitType_Effect), componentSubType: 2,
                                            componentManufacturer: 3)
        let secondID = try HostedAudioUnitID(componentType: UInt32(kAudioUnitType_Effect), componentSubType: 1,
                                             componentManufacturer: 3)
        let first = try HostedAudioUnitDescriptor(id: firstID, name: "Zed", manufacturerName: "Apple", version: 1)
        let second = try HostedAudioUnitDescriptor(id: secondID, name: "Alpha", manufacturerName: "Apple", version: 1)
        let sorted = try AudioUnitCatalog.validated([first, second])
        #expect(sorted.map(\.name) == ["Alpha", "Zed"])
        #expect(throws: HostedAudioUnitError.duplicateComponent) {
            try AudioUnitCatalog.validated([first, first])
        }

        let longName = String(repeating: "x", count: 257)
        #expect(throws: HostedAudioUnitError.invalidDescriptor) {
            try HostedAudioUnitDescriptor(id: firstID, name: longName, manufacturerName: "Apple", version: 1)
        }
        #expect(throws: HostedAudioUnitError.tooManyComponents) {
            try AudioUnitCatalog.validated(Array(repeating: first, count: 257))
        }
    }

    @Test func stateRequiresBinaryDictionaryAndDecodesThroughValidatedInitializer() throws {
        let id = try HostedAudioUnitID(componentType: UInt32(kAudioUnitType_Effect), componentSubType: 7,
                                       componentManufacturer: 8)
        let propertyList: [String: Any] = ["enabled": true, "gain": 0.5, "blob": Data([1, 2, 3])]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0)
        let state = try HostedAudioUnitState(id: id, data: data)
        #expect(state.id == id)
        #expect(try state.propertyList()["enabled"] as? Bool == true)
        let serializedState = try HostedAudioUnitState(id: id, documentState: propertyList)
        #expect(serializedState.id == id)
        #expect(try serializedState.propertyList()["gain"] as? Double == 0.5)

        #expect(throws: HostedAudioUnitError.stateUnavailable) {
            try HostedAudioUnitState(id: id, documentState: nil)
        }
        #expect(throws: HostedAudioUnitError.invalidState) {
            try HostedAudioUnitState(id: id, documentState: ["unsupported": NSObject()])
        }

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(HostedAudioUnitState.self, from: encoded)
        #expect(decoded == state)

        let xml = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        #expect(throws: HostedAudioUnitError.invalidState) {
            try HostedAudioUnitState(id: id, data: xml)
        }
        let scalar = try PropertyListSerialization.data(fromPropertyList: "not a dictionary", format: .binary, options: 0)
        #expect(throws: HostedAudioUnitError.invalidState) {
            try HostedAudioUnitState(id: id, data: scalar)
        }
        #expect(throws: HostedAudioUnitError.invalidState) {
            try HostedAudioUnitState(id: id, data: Data(repeating: 0, count: 1_048_577))
        }
    }

    @Test(.timeLimit(.minutes(1))) func discoveryIsEffectOnlyBoundedAndDeterministicallyOrdered() throws {
        let descriptors = try AudioUnitCatalog.discover()
        #expect(!descriptors.isEmpty)
        #expect(descriptors.count <= AudioUnitCatalog.maximumComponentCount)
        #expect(descriptors.allSatisfy { $0.id.componentType == UInt32(kAudioUnitType_Effect) })
        let comesBefore: (HostedAudioUnitDescriptor, HostedAudioUnitDescriptor) -> Bool = { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.manufacturerName != rhs.manufacturerName { return lhs.manufacturerName < rhs.manufacturerName }
            if lhs.id.componentType != rhs.id.componentType { return lhs.id.componentType < rhs.id.componentType }
            if lhs.id.componentSubType != rhs.id.componentSubType { return lhs.id.componentSubType < rhs.id.componentSubType }
            return lhs.id.componentManufacturer < rhs.id.componentManufacturer
        }
        let sorted = descriptors.sorted(by: comesBefore)
        #expect(descriptors.map(\.id) == sorted.map(\.id))
        for (left, right) in zip(descriptors, descriptors.dropFirst()) {
            #expect(!comesBefore(right, left))
        }
    }
}
