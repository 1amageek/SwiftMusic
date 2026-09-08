import CoreMIDI
import Foundation
import MusicPlaygourndCore

@main
struct MIDINativeTestHost {
    @MainActor static func main() {
        do {
            precondition(Thread.isMainThread)
            let service = try CoreMIDIService(clientName: "Native reconnect host")
            var client: MIDIClientRef = 0
            try check(MIDIClientCreateWithBlock("Native fixture" as CFString, &client, nil))
            var source: MIDIEndpointRef = 0
            try check(MIDISourceCreateWithProtocol(client, "Native source" as CFString,
                MIDIProtocolID(rawValue: 1)!, &source))
            var unique: MIDIUniqueID = 0
            try check(MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &unique))
            let id = try MIDIEndpointID(rawValue: unique)
            let originalSource = source
            let fixtureClient = client
            Task { @MainActor in
                do {
                    let descriptors = try await service.enumerateEndpoints()
                    guard descriptors.contains(where: { $0.id == id && $0.isVirtual }) else {
                        throw Failure.assertion("Native virtual endpoint discovery failed")
                    }
                    try await service.connectInput(id)
                    try check(MIDIEndpointDispose(originalSource))
                    try await wait {
                        let value = await service.snapshot()
                        return value.connectedInputIDs.isEmpty && value.clockHealth == .disconnected
                    }
                    var replacement: MIDIEndpointRef = 0
                    try check(MIDISourceCreateWithProtocol(fixtureClient, "Reconnected source" as CFString,
                        MIDIProtocolID(rawValue: 1)!, &replacement))
                    defer { MIDIEndpointDispose(replacement) }
                    try check(MIDIObjectSetIntegerProperty(replacement, kMIDIPropertyUniqueID, unique))
                    try await wait { await service.snapshot().connectedInputIDs == [id] }
                    let stream = try await service.eventStream()
                    var list = MIDIEventList()
                    let packet = MIDIEventListInit(&list, MIDIProtocolID(rawValue: 1)!)
                    var word: UInt32 = 0x20903c40
                    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet,
                        mach_absolute_time(), 1, &word)
                    try check(MIDIReceivedEventList(replacement, &list))
                    var iterator = stream.makeAsyncIterator()
                    guard let event = await iterator.next(), event.sourceID == id,
                          event.message == .noteOn(channel: 1, note: 60, velocity: 64) else {
                        throw Failure.assertion("Reconnected input was not delivered")
                    }
                    await service.shutdown()
                    guard await iterator.next() == nil else { throw Failure.assertion("Stream did not finish") }
                    print("native reconnect/input/shutdown passed")
                    MIDIClientDispose(fixtureClient)
                    exit(0)
                } catch {
                    await service.shutdown()
                    MIDIClientDispose(fixtureClient)
                    print("native MIDI failure: \(error)")
                    exit(1)
                }
            }
            RunLoop.main.run()
        } catch {
            print("native setup failure: \(error)")
            exit(1)
        }
    }

    private enum Failure: Error { case status(OSStatus), assertion(String) }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.status(status) }
    }
    @MainActor private static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.assertion("Endpoint transition timed out")
    }
}
