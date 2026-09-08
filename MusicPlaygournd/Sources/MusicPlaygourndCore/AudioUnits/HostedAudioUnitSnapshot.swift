import Foundation

public enum HostedAudioUnitSnapshot: Codable, Equatable, Sendable {
    case none
    case loaded(descriptor: HostedAudioUnitDescriptor, bypassed: Bool)
}
