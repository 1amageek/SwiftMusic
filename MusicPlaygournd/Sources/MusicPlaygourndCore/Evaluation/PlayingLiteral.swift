import Foundation

/// Locates a unique plain literal on an already compiler-identified line; it does not parse music.
public enum PlayingLiteral {
    /// Token boundaries are lexical only; their musical meaning and timing come from compiler events.
    public static func tokenRanges(pattern: String, line: Int, source: String) -> [NSRange] {
        guard let literal = range(pattern: pattern, line: line, source: source) else { return [] }
        let units = Array(pattern.utf16)
        let delimiters: Set<UInt16> = [9, 10, 11, 12, 13, 32, 60, 62, 91, 93]
        var ranges: [NSRange] = []
        var start: Int?
        for index in 0...units.count {
            if index == units.count || delimiters.contains(units[index]) {
                if let first = start {
                    ranges.append(NSRange(location: literal.location + 1 + first, length: index - first))
                    start = nil
                }
            } else if start == nil { start = index }
        }
        return ranges
    }

    public static func range(pattern: String, line: Int, source: String) -> NSRange? {
        guard line > 0, !pattern.contains("\\"), !pattern.contains("\""),
              !pattern.contains("\n"), !pattern.contains("\r") else { return nil }
        let text = source as NSString
        var offset = 0
        for _ in 1..<line {
            guard offset < text.length else { return nil }
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
        }
        guard offset < text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
        let literal = "\"\(pattern)\""
        let match = text.range(of: literal, options: .literal, range: lineRange)
        guard match.location != NSNotFound else { return nil }
        let tail = NSRange(location: NSMaxRange(match), length: NSMaxRange(lineRange) - NSMaxRange(match))
        guard text.range(of: literal, options: .literal, range: tail).location == NSNotFound else { return nil }
        // Plain direct modifier arguments only; never match comments, variables or raw-string interiors.
        let prefix = text.substring(with: NSRange(location: lineRange.location, length: match.location - lineRange.location))
        guard !prefix.contains("//"), !prefix.contains("/*"),
              prefix.range(of: #"\.(rhythm|notes)\s*\(\s*$"#, options: .regularExpression) != nil else { return nil }
        return match
    }
}
