import SwiftMusic

public protocol MIDIServiceProtocol: Sendable {
    func enumerateEndpoints() async throws -> [MIDIEndpointDescriptor]
    func connectInput(_ id: MIDIEndpointID) async throws
    func disconnectInput(_ id: MIDIEndpointID) async throws
    func setOutput(_ id: MIDIEndpointID?) async throws
    func eventStream() async throws -> AsyncStream<TimestampedMIDIEvent>
    func updateClockAnchor(_ anchor: PlaybackClockAnchor?) async
    func setClockMode(_ mode: MIDIClockMode) async throws
    func send(_ messages: [MIDIScheduledMessage], to id: MIDIEndpointID) async throws
    func schedule(loop: PreparedLoop, from startBeat: Double, through endBeat: Double,
                  channel: Int) async throws
    func scheduleClock(from startBeat: Double, through endBeat: Double) async throws
    func snapshot() async -> MIDIServiceSnapshot
    func shutdown() async
}
