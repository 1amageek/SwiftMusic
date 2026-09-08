import Foundation

/// Binary-property-list framing for the retained worker protocol.
public enum RenderWorkerFraming {
    public static let maximumPayloadBytes = 1_048_576
    public static let headerByteCount = 4

    /// Encodes one complete frame as a four-byte big-endian length followed by
    /// one binary-property-list Codable payload.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(value)
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw EvaluationError.invalidResult("Worker metadata exceeds 1 MiB.")
        }
        guard UInt32(exactly: payload.count) != nil else {
            throw EvaluationError.invalidResult("Worker metadata length cannot be represented.")
        }
        var frame = Data(capacity: headerByteCount + payload.count)
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(payload)
        return frame
    }

    /// Decodes one already-delimited binary-property-list payload.
    public static func decode<T: Decodable>(_ type: T.Type, payload: Data) throws -> T {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw EvaluationError.invalidResult("Worker metadata exceeds 1 MiB.")
        }
        return try PropertyListDecoder().decode(type, from: payload)
    }
}
