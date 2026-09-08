import Foundation

@MainActor
public protocol AudioUnitHosting: AnyObject {
    func discoverAudioEffects() throws -> [HostedAudioUnitDescriptor]
    func selectAudioEffect(_ id: HostedAudioUnitID, restoring state: HostedAudioUnitState?) async throws
    func clearAudioEffect() throws
    func setAudioEffectBypassed(_ bypassed: Bool) throws
    func captureAudioEffectState() throws -> HostedAudioUnitState
    func audioEffectSnapshot() -> HostedAudioUnitSnapshot
}
