import AVFoundation
import CoreMIDI
import Darwin
import Foundation
import Synchronization

private let midiOneProtocol = MIDIProtocolID(rawValue: 1)!

private struct MIDIActiveNote: Hashable, Sendable {
    let channel: Int
    let note: Int
}

private struct MIDISentNote: Sendable {
    let key: MIDIActiveNote
    var offHostTime: UInt64?
}

private final class MIDIClientNotificationBox: Sendable {
    private let state = Mutex(false)

    func signal() {
        state.withLock { $0 = true }
    }

    func consumeSignal() -> Bool {
        state.withLock { state in
            defer { state = false }
            return state
        }
    }
}

private struct MIDIReceiveContext: Sendable {
    let sourceID: MIDIEndpointID
    let ring: MIDIIngressRing

    init(sourceID: MIDIEndpointID, ring: MIDIIngressRing) {
        self.sourceID = sourceID
        self.ring = ring
    }
}

private func decodeMIDIMessage(_ message: MIDIUniversalMessage) -> MIDIMessage? {
    guard message.group == 0 else { return nil }
    switch message.type {
    case .channelVoice1:
        let voice = message.channelVoice1
        let channel = Int(voice.channel) + 1
        switch voice.status {
        case .noteOn:
            guard voice.note.number < 128, voice.note.velocity < 128 else { return nil }
            return MIDIMessage.noteOn(channel: channel, note: Int(voice.note.number),
                                      velocity: Int(voice.note.velocity)).normalized
        case .noteOff:
            guard voice.note.number < 128, voice.note.velocity < 128 else { return nil }
            return .noteOff(channel: channel, note: Int(voice.note.number),
                            velocity: Int(voice.note.velocity))
        case .controlChange:
            guard voice.controlChange.index < 128, voice.controlChange.data < 128 else { return nil }
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
    case .invalid:
        // This SDK's visitor exposes valid realtime system UMPs as raw unknown words.
        // Decode only the declared group-zero, one-word system messages with zero data bytes.
        let word = message.unknown.words.0
        guard word >> 24 == 0x10, word & 0xffff == 0 else { return nil }
        switch (word >> 16) & 0xff {
        case 0xf8: return .clock
        case 0xfa: return .start
        case 0xfb: return .continue
        case 0xfc: return .stop
        default: return nil
        }
    default:
        return nil
    }
}

private func midiEventVisitor(_ context: UnsafeMutableRawPointer?,
                              _ timeStamp: MIDITimeStamp,
                              _ message: MIDIUniversalMessage) {
    guard let context else { return }
    let receiveContext = context.assumingMemoryBound(to: MIDIReceiveContext.self).pointee
    guard let decoded = decodeMIDIMessage(message) else {
        receiveContext.ring.reportUnsupported()
        return
    }
    _ = receiveContext.ring.append(MIDIIngressRecord(sourceID: receiveContext.sourceID,
                                                      hostTime: timeStamp,
                                                      message: decoded))
}

private func endpointID(for endpoint: MIDIEndpointRef) throws -> MIDIEndpointID {
    var rawValue: MIDIUniqueID = 0
    let status = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &rawValue)
    guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    return try MIDIEndpointID(rawValue: rawValue)
}

private func endpointName(for endpoint: MIDIEndpointRef) throws -> String {
    var value: Unmanaged<CFString>?
    let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &value)
    guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    guard let value else { throw MIDIError.invalidEndpointName }
    return value.takeRetainedValue() as String
}

private func endpointIsVirtual(_ endpoint: MIDIEndpointRef) throws -> Bool {
    var entity = MIDIEntityRef()
    let status = MIDIEndpointGetEntity(endpoint, &entity)
    if status == kMIDIObjectNotFound, entity == 0 {
        // CoreMIDI reports no owning entity for a valid virtual endpoint with this status.
        // Validate the endpoint itself so a removed object is not classified as virtual.
        _ = try endpointID(for: endpoint)
        return true
    }
    guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    return entity == 0
}

private func endpointDescriptors() throws -> [MIDIEndpointDescriptor] {
    var descriptors: [MIDIEndpointDescriptor] = []
    var seen = Set<MIDIEndpointID>()

    for index in 0..<Int(MIDIGetNumberOfSources()) {
        let endpoint = MIDIGetSource(index)
        guard endpoint != 0 else { continue }
        let id = try endpointID(for: endpoint)
        guard seen.insert(id).inserted else { throw MIDIError.duplicateEndpoint(id) }
        let descriptor = try MIDIEndpointDescriptor(id: id, displayName: endpointName(for: endpoint),
                                                    direction: .input, isVirtual: endpointIsVirtual(endpoint))
        descriptors.append(descriptor)
    }
    for index in 0..<Int(MIDIGetNumberOfDestinations()) {
        let endpoint = MIDIGetDestination(index)
        guard endpoint != 0 else { continue }
        let id = try endpointID(for: endpoint)
        guard seen.insert(id).inserted else { throw MIDIError.duplicateEndpoint(id) }
        let descriptor = try MIDIEndpointDescriptor(id: id, displayName: endpointName(for: endpoint),
                                                    direction: .output, isVirtual: endpointIsVirtual(endpoint))
        descriptors.append(descriptor)
    }

    return descriptors.sorted {
        if $0.id != $1.id { return $0.id < $1.id }
        if $0.direction != $1.direction { return $0.direction.rawValue < $1.direction.rawValue }
        return $0.displayName < $1.displayName
    }
}

private func endpointReference(for id: MIDIEndpointID,
                              direction: MIDIEndpointDirection) throws -> MIDIEndpointRef {
    let count: Int
    let endpointAt: (Int) -> MIDIEndpointRef
    switch direction {
    case .input:
        count = Int(MIDIGetNumberOfSources())
        endpointAt = { MIDIGetSource($0) }
    case .output:
        count = Int(MIDIGetNumberOfDestinations())
        endpointAt = { MIDIGetDestination($0) }
    }
    for index in 0..<count {
        let endpoint = endpointAt(index)
        guard endpoint != 0 else { continue }
        if try endpointID(for: endpoint) == id { return endpoint }
    }
    throw MIDIError.endpointNotFound(id)
}

private func midiWord(for message: MIDIMessage) -> UInt32 {
    switch message {
    case .noteOn(let channel, let note, let velocity):
        return 0x2000_0000 | UInt32(0x90 | (channel - 1)) << 16
            | UInt32(note) << 8 | UInt32(velocity)
    case .noteOff(let channel, let note, let velocity):
        return 0x2000_0000 | UInt32(0x80 | (channel - 1)) << 16
            | UInt32(note) << 8 | UInt32(velocity)
    case .controlChange(let channel, let controller, let value):
        return 0x2000_0000 | UInt32(0xB0 | (channel - 1)) << 16
            | UInt32(controller) << 8 | UInt32(value)
    case .clock:
        return 0x1000_0000 | UInt32(0xF8) << 16
    case .start:
        return 0x1000_0000 | UInt32(0xFA) << 16
    case .continue:
        return 0x1000_0000 | UInt32(0xFB) << 16
    case .stop:
        return 0x1000_0000 | UInt32(0xFC) << 16
    }
}

public actor CoreMIDIService: MIDIServiceProtocol {
    private var client: MIDIClientRef
    private let notificationBox: MIDIClientNotificationBox
    private let ingress = MIDIIngressRing()
    private let clientName: String

    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var requestedInputIDs = Set<MIDIEndpointID>()
    private var sourceReferences: [MIDIEndpointID: MIDIEndpointRef] = [:]
    private var outputID: MIDIEndpointID?
    private var continuation: AsyncStream<TimestampedMIDIEvent>.Continuation?
    private var drainTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var anchor: PlaybackClockAnchor?
    private var clockMode: MIDIClockMode = .off
    private var clockHealth: MIDIClockHealth = .unavailable
    private var receivePulseTimes: [UInt64] = []
    private var receivedClockSourceID: MIDIEndpointID?
    private var receivedRunning = false
    private var receivedLastCommand: MIDIMessage?
    private var receivedCommandGeneration: UInt64 = 0
    private var receivePulseOrdinal: UInt64 = 0
    private var receivedBPM: Double?
    private var scheduleCursor = MIDIScheduleCursor()
    private var clockHasPlayed = false
    private var lastValidAnchor: PlaybackClockAnchor?
    private var clockSendRunning = false
    private var needsOutputFlush = false
    private var activeNotes: [MIDISentNote] = []
    private var lastIngressHostTime: [MIDIEndpointID: UInt64] = [:]
    private var reportedUnsupported: UInt64 = 0
    private var streamDrops: UInt64 = 0
    private var shutdownTask: Task<Void, Never>?
    private var isShutdown = false

    @MainActor public init(clientName: String = "MusicPlaygournd MIDI") throws {
        guard !clientName.isEmpty else { throw MIDIError.invalidEndpointName }
        try MIDIProcessClient.ensureAvailable()
        let box = MIDIClientNotificationBox()
        var client = MIDIClientRef()
        // Initialize on the app's serviced main run loop. CoreMIDI chooses the callback thread;
        // the callback transfers only a synchronized invalidation flag to this actor.
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client) { @Sendable _ in box.signal() }
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        self.client = client
        self.notificationBox = box
        self.clientName = clientName
        self.notificationTask = nil
        self.drainTask = nil
    }

    deinit {
        drainTask?.cancel()
        notificationTask?.cancel()
        if inputPort != 0 { _ = MIDIPortDispose(inputPort) }
        if outputPort != 0 { _ = MIDIPortDispose(outputPort) }
        if client != 0 { _ = MIDIClientDispose(client) }
    }

    public func enumerateEndpoints() async throws -> [MIDIEndpointDescriptor] {
        try ensureRunning()
        return try endpointDescriptors()
    }

    public func connectInput(_ id: MIDIEndpointID) async throws {
        try ensureRunning()
        try connectInputInternal(id)
    }

    private func connectInputInternal(_ id: MIDIEndpointID) throws {
        guard sourceReferences[id] == nil else { return }
        let source = try endpointReference(for: id, direction: .input)
        try ensureInputPort()
        // CoreMIDI carries this nonzero integer token without dereferencing it. No route-owned
        // pointer can outlive disconnect; the receive block borrows its stack context synchronously.
        let token = UnsafeMutableRawPointer(bitPattern: UInt(UInt32(bitPattern: id.rawValue)))
        let status = MIDIPortConnectSource(inputPort, source, token)
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        requestedInputIDs.insert(id)
        sourceReferences[id] = source
        startBackgroundTasksIfNeeded()
    }

    public func disconnectInput(_ id: MIDIEndpointID) async throws {
        try ensureRunning()
        requestedInputIDs.remove(id)
        guard let source = sourceReferences.removeValue(forKey: id) else { return }
        let status = MIDIPortDisconnectSource(inputPort, source)
        lastIngressHostTime.removeValue(forKey: id)
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    }

    public func eventStream() async throws -> AsyncStream<TimestampedMIDIEvent> {
        try ensureRunning()
        guard continuation == nil else { throw MIDIError.streamAlreadyClaimed }
        let pair = AsyncStream<TimestampedMIDIEvent>.makeStream(bufferingPolicy: .bufferingNewest(2_048))
        continuation = pair.continuation
        startBackgroundTasksIfNeeded()
        return pair.stream
    }

    private func startBackgroundTasksIfNeeded() {
        if notificationTask == nil {
        notificationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
                await self?.processNotificationsIfNeeded()
            }
        }
        }
        if drainTask == nil {
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000)
                } catch {
                    return
                }
                await self?.drainIngress()
            }
        }
        }
    }

    public func setOutput(_ id: MIDIEndpointID?) async throws {
        try ensureRunning()
        if let id { _ = try endpointReference(for: id, direction: .output) }
        guard id != outputID else { return }
        try flushOwnedOutput()
        outputID = id
        if case .send = clockMode { clockMode = .off }
        clockHasPlayed = false
        clockHealth = .unavailable
        startBackgroundTasksIfNeeded()
    }

    public func updateClockAnchor(_ anchor: PlaybackClockAnchor?) async {
        guard !isShutdown else { return }
        self.anchor = anchor
        guard let anchor else { return }
        let rewound = lastValidAnchor.map {
            anchor.isPlaying && anchor.accumulatedBeatPosition < $0.accumulatedBeatPosition
        } ?? false
        if !anchor.isPlaying || rewound {
            do { try flushOwnedOutput() }
            catch { clockHealth = .failed("MIDI output stop failed: \(error)"); return }
        }
        if rewound { clockHasPlayed = false }
        lastValidAnchor = anchor
    }

    public func setClockMode(_ mode: MIDIClockMode) async throws {
        try ensureRunning()
        guard mode != clockMode else { return }
        startBackgroundTasksIfNeeded()
        if clockSendRunning { try flushOwnedOutput() }
        switch mode {
        case .off:
            clockSendRunning = false
            scheduleCursor.resetClock()
            receivedClockSourceID = nil
            clockHealth = .unavailable
            receivePulseTimes.removeAll(keepingCapacity: true)
        case .send(let id):
            _ = try endpointReference(for: id, direction: .output)
            if outputID != id { try flushOwnedOutput() }
            outputID = id
            clockSendRunning = false
            scheduleCursor.resetClock()
            receivedClockSourceID = nil
            clockHealth = .waitingForPulses
        case .receive(let id):
            _ = try endpointReference(for: id, direction: .input)
            if sourceReferences[id] == nil { try connectInputInternal(id) }
            receivedClockSourceID = id
            receivePulseTimes.removeAll(keepingCapacity: true)
            receivePulseOrdinal = 0
            receivedRunning = false
            receivedLastCommand = nil
            receivedBPM = nil
            clockHealth = .waitingForPulses
        }
        clockMode = mode
    }

    public func send(_ messages: [MIDIScheduledMessage], to id: MIDIEndpointID) async throws {
        try ensureRunning()
        let destination = try endpointReference(for: id, direction: .output)
        let values = try validate(messages: messages)
        guard !values.isEmpty else { return }
        if outputID != id { try await setOutput(id) }
        try ensureOutputPort()
        let notes = try preparedNoteState(after: values)
        try send(values, to: destination)
        activeNotes = notes
        needsOutputFlush = true
    }

    public func schedule(loop: PreparedLoop, from startBeat: Double, through endBeat: Double,
                         channel: Int) async throws {
        do {
            try ensureRunning()
            guard let anchor, let outputID else { throw MIDIError.clockUnavailable }
            var candidate = scheduleCursor
            let messages = try candidate.notes(loop: loop, from: startBeat, through: endBeat,
                                               channel: channel, anchor: anchor)
            try transmitScheduled(messages, to: outputID)
            scheduleCursor = candidate
        } catch {
            recoverScheduleFailure(error)
            throw error
        }
    }

    public func scheduleClock(from startBeat: Double, through endBeat: Double) async throws {
        do {
            try ensureRunning()
            guard case .send(let destinationID) = clockMode, let anchor else {
                throw MIDIError.clockUnavailable
            }
            var candidate = scheduleCursor
            var messages = try candidate.clock(from: startBeat, through: endBeat, anchor: anchor)
            if !clockSendRunning {
                let command: MIDIMessage = clockHasPlayed && anchor.accumulatedBeatPosition > 0 ? .continue : .start
                messages.insert(MIDIScheduledMessage(hostTime: try messages.first?.hostTime ?? anchor.hostTime(atBeat: endBeat),
                                                     message: command), at: 0)
            }
            try transmitScheduled(messages, to: destinationID)
            scheduleCursor = candidate
            clockSendRunning = true
            clockHasPlayed = true
            clockHealth = .running
        } catch {
            recoverScheduleFailure(error)
            throw error
        }
    }

    private func recoverScheduleFailure(_ original: any Error) {
        defer { scheduleCursor = MIDIScheduleCursor() }
        do {
            try flushOwnedOutput()
            clockHealth = .failed(String(describing: original))
        } catch {
            clockHealth = .failed("MIDI scheduling failed: \(original); output cleanup also failed: \(error)")
        }
    }

    private func transmitScheduled(_ messages: [MIDIScheduledMessage], to id: MIDIEndpointID) throws {
        let destination = try endpointReference(for: id, direction: .output)
        let validated = try validate(messages: messages)
        guard !validated.isEmpty else { return }
        try ensureOutputPort()
        let notes = try preparedNoteState(after: validated)
        try send(validated, to: destination)
        activeNotes = notes
        needsOutputFlush = true
    }

    public func snapshot() async -> MIDIServiceSnapshot {
        MIDIServiceSnapshot(connectedInputIDs: sourceReferences.keys.sorted(), outputID: outputID,
                            clockMode: clockMode, clockHealth: clockHealth,
                            receivedClock: receivedClockState,
                            droppedEventCount: ingress.droppedCount > .max - streamDrops ? .max : ingress.droppedCount + streamDrops)
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        guard !isShutdown else { return }
        do { try flushOwnedOutput() }
        catch { clockHealth = .failed("MIDI shutdown output cleanup failed: \(error)") }
        isShutdown = true
        let drain = drainTask
        let notification = notificationTask
        drain?.cancel()
        notification?.cancel()
        continuation?.finish()
        continuation = nil
        if inputPort != 0 { _ = MIDIPortDispose(inputPort); inputPort = 0 }
        if outputPort != 0 { _ = MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { _ = MIDIClientDispose(client); client = 0 }
        sourceReferences.removeAll()
        requestedInputIDs.removeAll()
        anchor = nil
        outputID = nil
        clockMode = .off
        let task = Task { await drain?.value; await notification?.value }
        shutdownTask = task
        await task.value
    }

    private var receivedClockState: MIDIReceivedClockState? {
        guard case .receive = clockMode, let sourceID = receivedClockSourceID else { return nil }
        return MIDIReceivedClockState(sourceID: sourceID, isRunning: receivedRunning,
                                      lastCommand: receivedLastCommand,
                                      commandGeneration: receivedCommandGeneration,
                                      pulseOrdinal: receivePulseOrdinal,
                                      estimatedBPM: receivedBPM)
    }

    private func ensureRunning() throws {
        guard !isShutdown else { throw MIDIError.serviceShutDown }
    }

    private func ensureInputPort() throws {
        if inputPort != 0 { return }
        var port = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(client, "MusicPlaygournd MIDI Input" as CFString,
                                                      midiOneProtocol, &port) { @Sendable [ingress] list, token in
            guard let token else { ingress.reportUnsupported(); return }
            let rawID = Int32(truncatingIfNeeded: UInt(bitPattern: token))
            do {
                let context = MIDIReceiveContext(sourceID: try MIDIEndpointID(rawID), ring: ingress)
                // ForEachEvent invokes the visitor synchronously; this stack borrow never escapes.
                withUnsafePointer(to: context) {
                    MIDIEventListForEachEvent(list, midiEventVisitor, UnsafeMutableRawPointer(mutating: $0))
                }
            } catch { ingress.reportUnsupported() }
        }
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        inputPort = port
    }

    private func ensureOutputPort() throws {
        if outputPort != 0 { return }
        var port = MIDIPortRef()
        let status = MIDIOutputPortCreate(client, "MusicPlaygournd MIDI Output" as CFString, &port)
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        outputPort = port
    }

    private func validate(messages: [MIDIScheduledMessage]) throws -> [MIDIScheduledMessage] {
        guard messages.count <= 256 else { throw MIDIError.tooManyMessages(limit: 256) }
        guard !messages.isEmpty else { return [] }
        guard let anchor else { throw MIDIError.clockUnavailable }
        let now = mach_absolute_time()
        let oneSecond = AVAudioTime.hostTime(forSeconds: 1)
        var result: [MIDIScheduledMessage] = []
        result.reserveCapacity(messages.count)
        var previous: UInt64?
        for scheduled in messages {
            guard scheduled.hostTime > 0 else { throw MIDIError.invalidTimestamp(scheduled.hostTime) }
            guard scheduled.hostTime >= now else {
                throw MIDIError.invalidTimestamp(scheduled.hostTime)
            }
            guard scheduled.hostTime - now <= oneSecond else {
                throw MIDIError.timestampTooFar
            }
            if let previous, scheduled.hostTime < previous {
                throw MIDIError.timestampsNotNondecreasing
            }
            if scheduled.hostTime > anchor.presentationHostTime {
                let delta = scheduled.hostTime - anchor.presentationHostTime
                guard AVAudioTime.seconds(forHostTime: delta) <= 1 else {
                    throw MIDIError.timestampTooFar
                }
            }
            let message = try scheduled.message.validated()
            result.append(MIDIScheduledMessage(hostTime: scheduled.hostTime, message: message))
            previous = scheduled.hostTime
        }
        return result
    }

    private func send(_ messages: some Collection<MIDIScheduledMessage>, to destination: MIDIEndpointRef) throws {
        let byteCount = 65_536
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount,
                                                    alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { raw.deallocate() }
        // Own aligned raw storage until synchronous MIDISendEventList returns. CoreMIDI's
        // variable-length event-list API initializes packet bytes inside this fixed allocation.
        let eventList = raw.bindMemory(to: MIDIEventList.self, capacity: 1)
        var current = MIDIEventListInit(eventList, midiOneProtocol)
        for scheduled in messages {
            var word = midiWord(for: scheduled.message)
            let next = MIDIEventListAdd(eventList, byteCount, current, scheduled.hostTime, 1, &word)
            // The C API documents null on exhaustion but this SDK imports a nonoptional pointer.
            guard UInt(bitPattern: next) != 0 else {
                throw MIDIError.tooManyMessages(limit: 256)
            }
            current = next
        }
        let status = MIDISendEventList(outputPort, destination, eventList)
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
    }

    private func flushOwnedOutput() throws {
        guard needsOutputFlush else { scheduleCursor = MIDIScheduleCursor(); return }
        guard let outputID else {
            activeNotes.removeAll(keepingCapacity: true)
            clockSendRunning = false
            scheduleCursor = MIDIScheduleCursor()
            return
        }
        try ensureOutputPort()
        let destination = try endpointReference(for: outputID, direction: .output)
        let status = MIDIFlushOutput(destination)
        guard status == 0 else { throw MIDIError.coreMIDIStatus(status) }
        let now = mach_absolute_time()
        var messages: [MIDIScheduledMessage] = []
        messages.reserveCapacity(activeNotes.count + 1)
        for entry in activeNotes where entry.offHostTime.map({ $0 > now }) ?? true {
            let note = entry.key
            messages.append(MIDIScheduledMessage(hostTime: now,
                message: .noteOff(channel: note.channel, note: note.note, velocity: 0)))
        }
        if clockSendRunning {
            messages.append(MIDIScheduledMessage(hostTime: now, message: .stop))
        }
        for start in stride(from: 0, to: messages.count, by: 256) {
            try send(messages[start..<min(start + 256, messages.count)], to: destination)
        }
        activeNotes.removeAll(keepingCapacity: true)
        clockSendRunning = false
        needsOutputFlush = false
        scheduleCursor = MIDIScheduleCursor()
    }

    private func preparedNoteState(after messages: [MIDIScheduledMessage]) throws -> [MIDISentNote] {
        let now = mach_absolute_time()
        // Musical pending deadlines live in the cursor; this ledger retains sent occurrences
        // until their native off timestamp passes, including offs that a flush could cancel.
        var notes = activeNotes.filter { $0.offHostTime.map { $0 > now } ?? true }
        for scheduled in messages {
            switch scheduled.message {
            case .noteOn(let channel, let note, _):
                guard notes.count < 2_048 else { throw MIDIError.tooManyActiveNotes(limit: 2_048) }
                notes.append(MIDISentNote(key: MIDIActiveNote(channel: channel, note: note)))
            case .noteOff(let channel, let note, _):
                let key = MIDIActiveNote(channel: channel, note: note)
                if let index = notes.firstIndex(where: { $0.key == key && $0.offHostTime == nil }) {
                    notes[index].offHostTime = scheduled.hostTime
                }
            default: break
            }
        }
        return notes
    }

    private func drainIngress() {
        guard !isShutdown else { return }
        let unsupported = ingress.unsupportedCount
        if unsupported != reportedUnsupported {
            reportedUnsupported = unsupported
            clockHealth = .failed("Unsupported or malformed MIDI message")
        }
        let records = ingress.drain()
        guard !records.isEmpty else {
            processNotificationsIfNeeded()
            return
        }
        for record in records {
            guard requestedInputIDs.contains(record.sourceID) else { continue }
            if let previous = lastIngressHostTime[record.sourceID], record.hostTime < previous {
                clockHealth = .failed("host timestamps moved backwards")
                continue
            }
            lastIngressHostTime[record.sourceID] = record.hostTime
            var beat: Double?
            if let anchor, anchor.isPlaying {
                do {
                    beat = try anchor.beat(atHostTime: record.hostTime)
                } catch {
                    clockHealth = .failed("clock anchor conversion failed")
                }
            }
            let result = continuation?.yield(TimestampedMIDIEvent(sourceID: record.sourceID,
                                                      hostTime: record.hostTime,
                                                      message: record.message,
                                                      musicalBeat: beat))
            if case .dropped = result, streamDrops < .max { streamDrops += 1 }
            processClockMessage(record)
        }
        processNotificationsIfNeeded()
    }

    private func processClockMessage(_ record: MIDIIngressRecord) {
        guard case .receive(let inputID) = clockMode, inputID == record.sourceID else { return }
        switch record.message {
        case .start:
            receivePulseTimes.removeAll(keepingCapacity: true)
            receivePulseOrdinal = 0
            receivedRunning = true
            receivedLastCommand = .start
            guard receivedCommandGeneration < .max else { clockHealth = .failed("MIDI command limit reached"); return }
            receivedCommandGeneration += 1
            receivedBPM = nil
            clockHealth = .waitingForPulses
        case .continue:
            receivedRunning = true
            receivedLastCommand = .continue
            guard receivedCommandGeneration < .max else { clockHealth = .failed("MIDI command limit reached"); return }
            receivedCommandGeneration += 1
            clockHealth = .waitingForPulses
        case .stop:
            receivedRunning = false
            receivedLastCommand = .stop
            guard receivedCommandGeneration < .max else { clockHealth = .failed("MIDI command limit reached"); return }
            receivedCommandGeneration += 1
            clockHealth = .unavailable
        case .clock:
            guard receivedRunning else { return }
            guard receivePulseOrdinal < .max else { clockHealth = .failed("MIDI pulse limit reached"); return }
            guard receivePulseTimes.last.map({ record.hostTime > $0 }) ?? true else {
                clockHealth = .failed("MIDI clock interval is invalid"); return
            }
            receivePulseOrdinal += 1
            receivePulseTimes.append(record.hostTime)
            if receivePulseTimes.count > 25 { receivePulseTimes.removeFirst() }
            guard receivePulseTimes.count >= 25 else {
                clockHealth = .waitingForPulses
                return
            }
            let intervals = zip(receivePulseTimes.dropFirst(), receivePulseTimes).map {
                AVAudioTime.seconds(forHostTime: $0.0 - $0.1)
            }.filter { $0.isFinite && $0 > 0 }
            guard intervals.count == 24 else {
                clockHealth = .failed("MIDI clock interval is invalid")
                return
            }
            let sorted = intervals.sorted()
            let median = sorted[sorted.count / 2]
            let bpm = 60 / (median * 24)
            guard bpm.isFinite, (40...240).contains(bpm) else {
                clockHealth = .failed("MIDI clock tempo is out of range")
                return
            }
            receivedBPM = bpm
            clockHealth = .running
        default:
            break
        }
    }

    private func processNotificationsIfNeeded() {
        guard notificationBox.consumeSignal(), !isShutdown else { return }
        do {
            let descriptors = try endpointDescriptors()
            let availableInputs = Set(descriptors.filter { $0.direction == .input }.map(\.id))
            for id in requestedInputIDs {
                if !availableInputs.contains(id), let source = sourceReferences.removeValue(forKey: id) {
                    _ = MIDIPortDisconnectSource(inputPort, source)
                    lastIngressHostTime.removeValue(forKey: id)
                    clockHealth = .disconnected
                } else if availableInputs.contains(id), sourceReferences[id] == nil {
                    try connectInputInternal(id)
                }
            }
            if let outputID,
               !descriptors.contains(where: { $0.id == outputID && $0.direction == .output }) {
                clockHealth = .disconnected
                scheduleCursor = MIDIScheduleCursor()
                clockSendRunning = false
            } else if requestedInputIDs.isSubset(of: availableInputs), clockHealth == .disconnected {
                if needsOutputFlush { try flushOwnedOutput() }
                clockHealth = clockMode == .off ? .unavailable : .waitingForPulses
            }
        } catch {
            clockHealth = .failed("endpoint notification refresh failed: \(error)")
        }
    }
}
