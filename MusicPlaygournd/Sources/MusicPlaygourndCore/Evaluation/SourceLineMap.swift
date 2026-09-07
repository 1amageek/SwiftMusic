import Foundation

/// Tracks compiler line anchors through native UTF-16 text edits, without parsing Swift.
public struct SourceLineMap: Sendable {
    private var offsets: [Int: Int] = [:]

    public init(source: String, lines: [Int]) {
        let text = source as NSString
        var starts = [0]
        var position = 0
        while position < text.length {
            position = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            starts.append(position)
        }
        for line in lines where line > 0 && line <= starts.count {
            offsets[line] = starts[line - 1]
        }
    }

    public mutating func applyEdit(range: NSRange, replacement: String) {
        let delta = replacement.utf16.count - range.length
        for (line, offset) in offsets {
            if offset >= NSMaxRange(range) {
                offsets[line] = offset + delta
            } else if offset >= range.location {
                offsets.removeValue(forKey: line)
            }
        }
    }

    public func currentLine(for originalLine: Int, in source: String) -> Int? {
        guard let offset = offsets[originalLine] else { return nil }
        let text = source as NSString
        guard offset >= 0, offset < text.length else { return nil }
        var line = 1
        var position = 0
        while position < offset {
            let end = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            if end > offset { break }
            position = end
            line += 1
        }
        return line
    }
}
