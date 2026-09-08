import Foundation

/// Incremental frame parser that accepts arbitrary split or coalesced reads.
/// It retains at most one declared payload in addition to the four-byte header.
public struct RenderWorkerFrameParser: Sendable {
    private var header = [UInt8]()
    private var expectedPayloadLength: Int?
    private var payload = Data()

    public init() {}

    /// Appends bytes from one pipe read and returns every complete payload.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        var completed: [Data] = []
        for byte in bytes {
            if expectedPayloadLength == nil {
                header.append(byte)
                if header.count == RenderWorkerFraming.headerByteCount {
                    let length = header.reduce(UInt32(0)) { partial, byte in
                        (partial << 8) | UInt32(byte)
                    }
                    guard length > 0, length <= RenderWorkerFraming.maximumPayloadBytes else {
                        throw EvaluationError.invalidResult("Worker frame length is outside the 1 MiB bound.")
                    }
                    expectedPayloadLength = Int(length)
                    payload.removeAll(keepingCapacity: true)
                    payload.reserveCapacity(Int(length))
                    header.removeAll(keepingCapacity: true)
                }
                continue
            }

            payload.append(byte)
            guard let expectedPayloadLength else { continue }
            if payload.count == expectedPayloadLength {
                completed.append(payload)
                payload.removeAll(keepingCapacity: true)
                self.expectedPayloadLength = nil
            }
        }
        return completed
    }

    /// Rejects a truncated frame when the child closes its protocol stream.
    public mutating func finish() throws {
        guard header.isEmpty, expectedPayloadLength == nil, payload.isEmpty else {
            throw EvaluationError.invalidResult("Worker protocol ended inside a frame.")
        }
    }
}
