import Foundation

struct SwiftCompletionFrameParser {
    private var buffer = Data()

    mutating func append(_ byte: UInt8) throws -> [Data] {
        buffer.append(byte)
        guard buffer.count <= SwiftCompletionConnection.maximumMessageBytes + 8 * 1024 else {
            throw SwiftCompletionError.protocolError("The LSP frame exceeds 4 MiB.")
        }

        var frames: [Data] = []
        while let separator = Self.headerSeparator(in: buffer) {
            let headerData = buffer[..<separator.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8),
                  let length = Self.contentLength(in: header),
                  length >= 0, length <= SwiftCompletionConnection.maximumMessageBytes else {
                throw SwiftCompletionError.protocolError("The LSP Content-Length header is invalid.")
            }
            let bodyStart = separator.upperBound
            guard buffer.count >= bodyStart + length else { break }
            frames.append(Data(buffer[bodyStart..<(bodyStart + length)]))
            buffer.removeSubrange(..<(bodyStart + length))
        }
        if buffer.count > 8 * 1024, Self.headerSeparator(in: buffer) == nil {
            throw SwiftCompletionError.protocolError("The LSP header exceeds its bound.")
        }
        return frames
    }

    private static func headerSeparator(in data: Data) -> Range<Data.Index>? {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) { return range }
        if let range = data.range(of: Data("\n\n".utf8)) { return range }
        return nil
    }

    private static func contentLength(in header: String) -> Int? {
        for line in header.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count == 2, fields[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                return Int(fields[1])
            }
        }
        return nil
    }
}
