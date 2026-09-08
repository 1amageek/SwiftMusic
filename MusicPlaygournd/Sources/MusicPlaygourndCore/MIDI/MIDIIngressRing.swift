import Synchronization

internal struct MIDIIngressRecord: Sendable, Equatable {
    let sourceID: MIDIEndpointID
    let hostTime: UInt64
    let message: MIDIMessage
}

internal final class MIDIIngressRing: Sendable {
    static let capacity = 2_048

    private struct State: Sendable {
        var records: [MIDIIngressRecord?] = Array(repeating: nil, count: MIDIIngressRing.capacity)
        var readIndex = 0
        var count = 0
        var dropped: UInt64 = 0
        var unsupported: UInt64 = 0
    }

    private let state = Mutex(State())

    @discardableResult
    func append(_ record: MIDIIngressRecord) -> Bool {
        state.withLock { state in
            let index = (state.readIndex + state.count) % Self.capacity
            var dropped = false
            if state.count == Self.capacity {
                state.records[state.readIndex] = record
                state.readIndex = (state.readIndex + 1) % Self.capacity
                if state.dropped < UInt64.max { state.dropped += 1 }
                dropped = true
            } else {
                state.records[index] = record
                state.count += 1
            }
            return dropped
        }
    }

    func drain() -> [MIDIIngressRecord] {
        state.withLock { state in
            var result: [MIDIIngressRecord] = []
            result.reserveCapacity(state.count)
            for _ in 0..<state.count {
                result.append(state.records[state.readIndex]!)
                state.records[state.readIndex] = nil
                state.readIndex = (state.readIndex + 1) % Self.capacity
            }
            state.count = 0
            return result
        }
    }

    var droppedCount: UInt64 {
        state.withLock { $0.dropped }
    }

    /// Records an event that was rejected at the callback boundary without
    /// allocating a diagnostic object on the realtime callback.
    func reportUnsupported() {
        state.withLock {
            if $0.unsupported < UInt64.max { $0.unsupported += 1 }
        }
    }

    var unsupportedCount: UInt64 {
        state.withLock { $0.unsupported }
    }
}
