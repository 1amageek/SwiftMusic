import Foundation

/// Resolves one compiler-provided declaration anchor to a plain string argument.
///
/// The evaluator only maps a literal when the anchor identifies one unambiguous
/// call on the same source line. It never falls back to the first matching text.
enum SourceAnchorLocations {
    struct LiteralArgument {
        let contentRange: NSRange
        let value: String
    }

    private struct Candidate {
        let methodStart: Int
        let close: Int
        let contentStart: Int
        let contentEnd: Int
        let value: String
    }

    static func literalArgument(
        source: String,
        fileID: String,
        line: Int,
        column: Int,
        methodNames: [String],
        expectedValue: String
    ) -> LiteralArgument? {
        guard isSessionFile(fileID), line > 0, column > 0,
              !methodNames.isEmpty, !expectedValue.isEmpty else {
            return nil
        }
        let text = source as NSString
        var lineStart = 0
        for _ in 1..<line {
            guard lineStart < text.length else { return nil }
            lineStart = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
        }
        guard lineStart < text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
        let lineText = text.substring(with: lineRange)
        let candidates = candidates(in: lineText, methodNames: methodNames)
            .filter { $0.value == expectedValue }
        guard !candidates.isEmpty else { return nil }

        let anchorByte = column - 1
        guard anchorByte <= lineText.utf8.count else { return nil }
        let containing = candidates.filter { $0.methodStart <= anchorByte && anchorByte <= $0.close }
        let selected: Candidate?
        let exactStarts = candidates.filter { $0.methodStart == anchorByte }
        if exactStarts.count == 1 {
            selected = exactStarts[0]
        } else if containing.count == 1 {
            selected = containing[0]
        } else if !containing.isEmpty {
            let shortest = containing.map { $0.close - $0.methodStart }.min()
            let narrowed = containing.filter { $0.close - $0.methodStart == shortest }
            selected = narrowed.count == 1 ? narrowed[0] : nil
        } else {
            selected = nil
        }
        guard let selected,
              selected.contentStart >= 0,
              selected.contentEnd > selected.contentStart,
              selected.contentEnd <= lineText.utf8.count else {
            return nil
        }
        let bytes = Array(lineText.utf8)
        let prefix = String(decoding: bytes[..<selected.contentStart], as: UTF8.self)
        let content = String(decoding: bytes[selected.contentStart..<selected.contentEnd], as: UTF8.self)
        let utf16Start = prefix.utf16.count
        let utf16Length = content.utf16.count
        guard utf16Length > 0 else { return nil }
        return LiteralArgument(
            contentRange: NSRange(location: lineRange.location + utf16Start, length: utf16Length),
            value: selected.value
        )
    }

    static func isSessionFile(_ fileID: String) -> Bool {
        fileID == "Session.swift" || fileID.hasSuffix("/Session.swift")
    }

    private static func candidates(in line: String, methodNames: [String]) -> [Candidate] {
        let bytes = Array(line.utf8)
        let methods = methodNames.map { ($0, Array($0.utf8)) }
        var result: [Candidate] = []
        var index = 0
        while index < bytes.count {
            if bytes[index] == 47, index + 1 < bytes.count, bytes[index + 1] == 47 { break }
            if bytes[index] == 34 {
                index = skipString(bytes, from: index)
                continue
            }
            for (name, nameBytes) in methods where matches(bytes, nameBytes, at: index) {
                let afterName = index + nameBytes.count
                guard isIdentifierBoundary(bytes, before: index),
                      isIdentifierBoundary(bytes, at: afterName) else { continue }
                var open = afterName
                while open < bytes.count, isWhitespace(bytes[open]) { open += 1 }
                guard open < bytes.count, bytes[open] == 40,
                      precedingCharacterIsDot(bytes, before: index) else { continue }
                guard let close = matchingParenthesis(bytes, from: open),
                      let literal = firstPlainStringArgument(bytes, after: open) else { continue }
                let value = String(decoding: bytes[literal.start..<literal.end], as: UTF8.self)
                result.append(Candidate(methodStart: index, close: close,
                                        contentStart: literal.start, contentEnd: literal.end,
                                        value: value))
                _ = name
            }
            index += 1
        }
        return result
    }

    private static func matches(_ bytes: [UInt8], _ pattern: [UInt8], at index: Int) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        return bytes[index..<(index + pattern.count)].elementsEqual(pattern)
    }

    private static func isIdentifierBoundary(_ bytes: [UInt8], before index: Int) -> Bool {
        guard index > 0 else { return true }
        return !isIdentifierByte(bytes[index - 1])
    }

    private static func isIdentifierBoundary(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else { return true }
        return !isIdentifierByte(bytes[index])
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) || byte == 95
    }

    private static func precedingCharacterIsDot(_ bytes: [UInt8], before index: Int) -> Bool {
        var cursor = index
        while cursor > 0, isWhitespace(bytes[cursor - 1]) { cursor -= 1 }
        return cursor > 0 && bytes[cursor - 1] == 46
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 11 || byte == 12 || byte == 13 || byte == 32
    }

    private static func skipString(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == 92 {
                index += min(2, bytes.count - index)
            } else if bytes[index] == 34 {
                return index + 1
            } else {
                index += 1
            }
        }
        return bytes.count
    }

    private static func matchingParenthesis(_ bytes: [UInt8], from open: Int) -> Int? {
        var depth = 1
        var index = open + 1
        while index < bytes.count {
            if bytes[index] == 34 {
                index = skipString(bytes, from: index)
                continue
            }
            if bytes[index] == 40 {
                depth += 1
            } else if bytes[index] == 41 {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    private static func firstPlainStringArgument(
        _ bytes: [UInt8], after open: Int
    ) -> (start: Int, end: Int)? {
        var index = open + 1
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        let start = index + 1
        index = start
        while index < bytes.count {
            if bytes[index] == 92 { return nil }
            if bytes[index] == 34 { return (start, index) }
            if bytes[index] == 10 || bytes[index] == 13 { return nil }
            index += 1
        }
        return nil
    }
}
