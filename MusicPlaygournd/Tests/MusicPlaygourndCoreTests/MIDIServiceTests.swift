import AVFoundation
import CoreMIDI
import Darwin
import Foundation
import Synchronization
import Testing
@testable import MusicPlaygourndCore

extension NativeHostTests {
@MainActor
struct MIDIServiceTests {
    @Test(.timeLimit(.minutes(1)))
    func serviceCanRestartAfterSessionClientsAreDisposed() async throws {
        for index in 0..<3 {
            let service = try CoreMIDIService(clientName: "Restart \(index)")
            do {
                let endpoints = try VirtualMIDIEndpoints(label: "restart \(index)")
                let destination = try endpoints.destinationID
                let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.03)
                await service.updateClockAnchor(try PlaybackClockAnchor(
                    presentationHostTime: host, accumulatedBeatPosition: 0,
                    beatsPerMinute: 120, loopBeatCount: 4, revision: 1,
                    overrideGeneration: 0, isPlaying: true))
                try await service.send([MIDIScheduledMessage(
                    hostTime: host,
                    message: .controlChange(channel: 1, controller: 7, value: index))], to: destination)
                let messages = try await endpoints.waitForMessages(atLeast: 1)
                #expect(messages.last?.message == .controlChange(channel: 1, controller: 7, value: index))
                await service.shutdown()
                await service.shutdown()
            } catch {
                await service.shutdown()
                throw error
            }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func virtualUMPInputMapsAnchorAndNormalizesZeroVelocity() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "input")
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Input Test")
        let sourceID = try endpoints.sourceID
        try await service.connectInput(sourceID)
        let stream = try await service.eventStream()
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.5)
        let anchor = try PlaybackClockAnchor(presentationHostTime: anchorHostTime,
            accumulatedBeatPosition: 4, beatsPerMinute: 120, loopBeatCount: 4,
            revision: 1, overrideGeneration: 0, isPlaying: true)
        await service.updateClockAnchor(anchor)

        try endpoints.inject([0x20903c00], at: anchorHostTime)
        let event = try await nextEvent(from: stream)
        #expect(event.sourceID == sourceID)
        #expect(event.message == .noteOff(channel: 1, note: 60, velocity: 0))
        #expect(event.musicalBeat != nil)
        if let musicalBeat = event.musicalBeat {
            #expect(abs(musicalBeat - 4) < 0.000001)
        }
        await service.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func virtualUMPOutputRoundTripAndClockOnlyScheduling() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "output")
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Output Test")
        let destinationID = try endpoints.destinationID
        try await service.setOutput(destinationID)
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.5)
        await service.updateClockAnchor(try PlaybackClockAnchor(
            presentationHostTime: anchorHostTime, accumulatedBeatPosition: 0,
            beatsPerMinute: 120, loopBeatCount: 4, revision: 1,
            overrideGeneration: 0, isPlaying: true))

        try await service.setClockMode(.send(output: destinationID))
        try await service.scheduleClock(from: 0, through: 0.05)
        let noteHostTime = anchorHostTime + AVAudioTime.hostTime(forSeconds: 0.05)
        try await service.send([
            MIDIScheduledMessage(hostTime: noteHostTime,
                                 message: .noteOn(channel: 1, note: 60, velocity: 100))
        ], to: destinationID)
        let messages = try await endpoints.waitForMessages(atLeast: 4)
        #expect(messages.contains { $0.message == .noteOn(channel: 1, note: 60, velocity: 100) })
        let clockMessages = messages.map(\.message)
        #expect(clockMessages.contains(.start))
        #expect(clockMessages.contains(.clock))
        await service.shutdown()
    }

    @Test(.timeLimit(.minutes(2)))
    func receivedClockSnapshotTracksCommandsPulsesAndTempo() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "clock")
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Clock Test")
        let sourceID = try endpoints.sourceID
        try await service.setClockMode(.receive(input: sourceID))
        _ = try await service.eventStream()

        let start = mach_absolute_time()
        let pulseSpacing = AVAudioTime.hostTime(forSeconds: 60 / (120 * 24))
        let words = [UInt32](repeating: 0x10F80000, count: 26).enumerated().map { index, word in
            index == 0 ? UInt32(0x10FA0000) : word
        }
        try endpoints.inject(words, at: start, spacing: pulseSpacing)

        var received: MIDIReceivedClockState?
        for _ in 0..<80 {
            let snapshot = await service.snapshot()
            received = snapshot.receivedClock
            if let received, received.pulseOrdinal == 25, received.estimatedBPM != nil {
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw MIDITestError.timeout
            }
        }
        let state = try #require(received)
        #expect(state.sourceID == sourceID)
        #expect(state.isRunning)
        #expect(state.lastCommand == .start)
        #expect(state.commandGeneration == 1)
        #expect(state.pulseOrdinal == 25)
        #expect(abs(state.beat - (25.0 / 24.0)) < 0.000001)
        if let estimatedBPM = state.estimatedBPM {
            #expect(abs(estimatedBPM - 120) < 0.5)
        }
        await service.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func ingressRingDropsOldestRecordAtFixedCapacity() throws {
        let ring = MIDIIngressRing()
        let sourceID = try MIDIEndpointID(rawValue: 1)
        for index in 0..<(MIDIIngressRing.capacity + 2) {
            _ = ring.append(MIDIIngressRecord(sourceID: sourceID, hostTime: UInt64(index),
                message: .noteOn(channel: 1, note: index % 128, velocity: 1)))
        }
        #expect(ring.droppedCount == 2)
        let records = ring.drain()
        #expect(records.count == MIDIIngressRing.capacity)
        #expect(records.first?.hostTime == 2)
        #expect(records.last?.hostTime == 2_049)
        ring.reportUnsupported()
        #expect(ring.unsupportedCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidOrderingSevenBitDeadlineAndMixedBatchRejectBeforeOutput() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "validation")
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Validation Test")
        let destinationID = try endpoints.destinationID
        try await service.setOutput(destinationID)
        let anchorHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.4)
        await service.updateClockAnchor(try PlaybackClockAnchor(
            presentationHostTime: anchorHostTime, accumulatedBeatPosition: 0,
            beatsPerMinute: 120, loopBeatCount: 4, revision: 1,
            overrideGeneration: 0, isPlaying: true))

        let future = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.2)
        let later = future + AVAudioTime.hostTime(forSeconds: 0.01)
        do {
            try await service.send([
                MIDIScheduledMessage(hostTime: later,
                                     message: .noteOn(channel: 1, note: 60, velocity: 100)),
                MIDIScheduledMessage(hostTime: future,
                                     message: .noteOff(channel: 1, note: 60, velocity: 0))
            ], to: destinationID)
            Issue.record("Descending MIDI timestamps were accepted")
        } catch let error as MIDIError {
            #expect(error == .timestampsNotNondecreasing)
        }

        do {
            try await service.send([
                MIDIScheduledMessage(hostTime: future,
                                     message: .noteOn(channel: 1, note: 60, velocity: 128))
            ], to: destinationID)
            Issue.record("A non-seven-bit MIDI velocity was accepted")
        } catch let error as MIDIError {
            #expect(error == .invalidMessage("velocity must be in 0...127"))
        }

        let past = mach_absolute_time() - AVAudioTime.hostTime(forSeconds: 0.05)
        do {
            try await service.send([
                MIDIScheduledMessage(hostTime: past,
                                     message: .noteOn(channel: 1, note: 60, velocity: 1))
            ], to: destinationID)
            Issue.record("A past MIDI timestamp was accepted")
        } catch let error as MIDIError {
            #expect(error == .invalidTimestamp(past))
        }

        do {
            try await service.send([
                MIDIScheduledMessage(hostTime: future,
                                     message: .noteOn(channel: 1, note: 60, velocity: 1)),
                MIDIScheduledMessage(hostTime: later,
                                     message: .noteOn(channel: 1, note: 61, velocity: 128))
            ], to: destinationID)
            Issue.record("A mixed valid/invalid MIDI batch was partially accepted")
        } catch let error as MIDIError {
            #expect(error == .invalidMessage("velocity must be in 0...127"))
        }
        #expect(endpoints.captureSnapshot().isEmpty)
        await service.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedUMPMarksClockHealthWithoutYieldingFakeInput() async throws {
        let endpoints = try VirtualMIDIEndpoints(label: "unsupported")
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Unsupported Test")
        let sourceID = try endpoints.sourceID
        try await service.connectInput(sourceID)
        _ = try await service.eventStream()
        try endpoints.inject([0x21203c40], at: mach_absolute_time())

        var health: MIDIClockHealth = .unavailable
        for _ in 0..<80 {
            health = await service.snapshot().clockHealth
            if case .failed(let reason) = health {
                #expect(reason.contains("Unsupported or malformed MIDI message"))
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw MIDITestError.timeout
            }
        }
        guard case .failed = health else {
            Issue.record("Unsupported UMP did not update clock health")
            await service.shutdown()
            return
        }
        await service.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func endpointRemovalAndReappearanceReconnectsOneInputByStableID() async throws {
        let executable = try Self.resolveNativeTestHost()
        let process = Process()
        let output = Pipe()
        let completion = ProcessCompletion()
        process.executableURL = executable
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { task in
            completion.finish(status: task.terminationStatus,
                              exited: task.terminationReason == .exit)
        }
        try process.run()

        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while completion.result == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let result = completion.result else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw MIDITestError.timeout
        }
        let diagnostic = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
        guard result.exited, result.status == 0 else {
            throw MIDITestError.nativeHostFailed(diagnostic)
        }
    }

    private static func resolveNativeTestHost() throws -> URL {
        var directory = Bundle(for: MIDITestBundle.self).bundleURL
        while directory.path != "/" {
            let executable = directory.appending(path: "MIDINativeTestHost")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            directory.deleteLastPathComponent()
        }
        throw MIDITestError.nativeHostUnavailable
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownFinishesStreamAndRejectsLaterOperations() async throws {
        let service = try CoreMIDIService(clientName: "MusicPlaygournd MIDI Shutdown Test")
        let stream = try await service.eventStream()
        await service.shutdown()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        await service.shutdown()
        do {
            _ = try await service.enumerateEndpoints()
            Issue.record("A shut down MIDI service accepted an operation")
        } catch let error as MIDIError {
            #expect(error == .serviceShutDown)
        }
    }
}

}

private final class MIDITestBundle: NSObject {}

private enum MIDITestError: Error {
    case timeout
    case streamEnded
    case nativeHostUnavailable
    case nativeHostFailed(String)
}

struct CapturedMIDIMessage: Sendable, Equatable {
    let hostTime: UInt64
    let message: MIDIMessage
}

final class MIDIOutputCapture: Sendable {
    private let messages = Mutex<[CapturedMIDIMessage]>([])

    func append(_ message: MIDIMessage, at hostTime: UInt64) {
        messages.withLock { $0.append(CapturedMIDIMessage(hostTime: hostTime, message: message)) }
    }

    func snapshot() -> [CapturedMIDIMessage] {
        messages.withLock { $0 }
    }
}

@MainActor
final class VirtualMIDIEndpoints: Sendable {
    private static let protocolID = MIDIProtocolID(rawValue: 1)!

    let client: MIDIClientRef
    private let sourceState: Mutex<MIDIEndpointRef>
    let destination: MIDIEndpointRef
    private let capture: MIDIOutputCapture

    init(label: String) throws {
        let uniqueLabel = "MusicPlaygournd \(label) \(UUID().uuidString)"
        var client = MIDIClientRef()
        var status = MIDIClientCreateWithBlock(uniqueLabel as CFString, &client) { @Sendable _ in }
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        self.client = client

        var source = MIDIEndpointRef()
        status = MIDISourceCreateWithProtocol(client, "\(uniqueLabel) Source" as CFString,
                                               Self.protocolID, &source)
        guard status == 0 else {
            _ = MIDIClientDispose(client)
            throw MIDIError.coreMIDIStatus(status)
        }
        self.sourceState = Mutex(source)
        let capture = MIDIOutputCapture()
        self.capture = capture
        let destinationResult = makeVirtualMIDIDestination(
            client: client,
            name: "\(uniqueLabel) Destination" as CFString,
            protocolID: Self.protocolID,
            capture: capture)
        guard destinationResult.status == 0 else {
            _ = MIDIEndpointDispose(source)
            _ = MIDIClientDispose(client)
            throw MIDIError.coreMIDIStatus(destinationResult.status)
        }
        self.destination = destinationResult.endpoint
    }

    deinit {
        let source = sourceState.withLock { source in
            defer { source = 0 }
            return source
        }
        if source != 0 { _ = MIDIEndpointDispose(source) }
        if destination != 0 { _ = MIDIEndpointDispose(destination) }
        _ = MIDIClientDispose(client)
    }

    var sourceID: MIDIEndpointID {
        get throws {
            let source = sourceState.withLock { $0 }
            guard source != 0 else { throw MIDIError.invalidMessage("source is unavailable") }
            return try endpointID(for: source)
        }
    }

    var destinationID: MIDIEndpointID {
        get throws { try endpointID(for: destination) }
    }

    func inject(_ words: [UInt32], at hostTime: UInt64,
                spacing: UInt64 = 0) throws {
        guard !words.isEmpty else { return }
        let source = sourceState.withLock { $0 }
        guard source != 0 else { throw MIDIError.invalidMessage("source is unavailable") }
        let byteCount = 16_384
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                    alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIEventList.self)
        var packet = MIDIEventListInit(list, Self.protocolID)
        for (index, word) in words.enumerated() {
            var value = word
            packet = MIDIEventListAdd(list, byteCount, packet,
                                      hostTime + UInt64(index) * spacing, 1, &value)
        }
        let status = MIDIReceivedEventList(source, UnsafePointer(list))
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    }

    func captureSnapshot() -> [CapturedMIDIMessage] {
        capture.snapshot()
    }

    func waitForMessages(atLeast count: Int) async throws -> [CapturedMIDIMessage] {
        for _ in 0..<80 {
            let values = capture.snapshot()
            if values.count >= count { return values }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw MIDITestError.timeout
            }
        }
        throw MIDITestError.timeout
    }
}

private func midiTestOutputVisitor(_ refCon: UnsafeMutableRawPointer?, _ hostTime: MIDITimeStamp,
                                   _ message: MIDIUniversalMessage) {
    guard let refCon else { return }
    let capture = Unmanaged<MIDIOutputCapture>.fromOpaque(refCon).takeUnretainedValue()
    if let decoded = decodeMIDIMessageForTest(message) {
        capture.append(decoded, at: hostTime)
    }
}

private func makeVirtualMIDIDestination(
    client: MIDIClientRef,
    name: CFString,
    protocolID: MIDIProtocolID,
    capture: MIDIOutputCapture
) -> (status: OSStatus, endpoint: MIDIEndpointRef) {
    var endpoint = MIDIEndpointRef()
    let status = MIDIDestinationCreateWithProtocol(client, name, protocolID, &endpoint) { @Sendable list, _ in
        MIDIEventListForEachEvent(list, midiTestOutputVisitor,
                                  Unmanaged.passUnretained(capture).toOpaque())
    }
    return (status, endpoint)
}

private func endpointID(for endpoint: MIDIEndpointRef) throws -> MIDIEndpointID {
    var value: MIDIUniqueID = 0
    let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value)
    guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    return try MIDIEndpointID(rawValue: value)
}

private func decodeMIDIMessageForTest(_ message: MIDIUniversalMessage) -> MIDIMessage? {
    guard message.group == 0 else { return nil }
    if message.type == .invalid {
        let word: UInt32? = withUnsafeBytes(of: message) { rawBytes in
            guard rawBytes.count >= 12 else { return nil }
            return rawBytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        }
        guard let word,
              ((word >> 28) & 0x0F) == 1 else { return nil }
        switch UInt8((word >> 16) & 0xFF) {
        case 0xF8: return .clock
        case 0xFA: return .start
        case 0xFB: return .continue
        case 0xFC: return .stop
        default: return nil
        }
    }
    switch message.type {
    case .channelVoice1:
        let voice = message.channelVoice1
        let channel = Int(voice.channel) + 1
        switch voice.status {
        case .noteOn:
            return MIDIMessage.noteOn(channel: channel, note: Int(voice.note.number),
                                      velocity: Int(voice.note.velocity)).normalized
        case .noteOff:
            return .noteOff(channel: channel, note: Int(voice.note.number),
                            velocity: Int(voice.note.velocity))
        case .controlChange:
            return .controlChange(channel: channel, controller: Int(voice.controlChange.index),
                                  value: Int(voice.controlChange.data))
        default:
            return nil
        }
    case .system:
        switch message.system.status {
        case .statusTimingClock: return .clock
        case .statusStart: return .start
        case .statusContinue: return .continue
        case .statusStop: return .stop
        default: return nil
        }
    default:
        return nil
    }
}

private func nextEvent(from stream: AsyncStream<TimestampedMIDIEvent>) async throws
    -> TimestampedMIDIEvent {
    try await withThrowingTaskGroup(of: TimestampedMIDIEvent.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let event = await iterator.next() else { throw MIDITestError.streamEnded }
            return event
        }
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                throw MIDITestError.timeout
            }
            throw MIDITestError.timeout
        }
        defer { group.cancelAll() }
        guard let event = try await group.next() else { throw MIDITestError.timeout }
        return event
    }
}
