import Foundation
import SwiftMusic

/// Reads complete expression ranges from the same compiler that evaluates the session.
struct ExpressionResultLocations {
    static func lines(ast: Data, source: String, prefixBytes: Int, rows: [LoopRow]) throws -> [Int: Int] {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: ast) as? [String: Any],
                  object["_kind"] as? String == "source_file" else {
                throw EvaluationError.invalidResult("Unsupported Swift AST format for inline results.")
            }
            root = object
        } catch let error as EvaluationError { throw error }
        catch { throw EvaluationError.invalidResult("Invalid Swift AST for inline results: \(error.localizedDescription)") }
        let bytes = Array(source.utf8)
        var starts = [0]
        for (index, byte) in bytes.enumerated() where byte == 10 { starts.append(index + 1) }
        var ranges: [ClosedRange<Int>] = []
        var pending: [Any] = [root]
        while let value = pending.popLast() {
            if let object = value as? [String: Any] {
                if object["_kind"] as? String == "call_expr", object["implicit"] as? Bool != true,
                   let range = object["range"] as? [String: Any],
                   let start = range["start"] as? Int, let end = range["end"] as? Int,
                   start >= prefixBytes, end >= start, end < prefixBytes + bytes.count {
                    ranges.append((start - prefixBytes)...(end - prefixBytes))
                }
                pending.append(contentsOf: object.values)
            } else if let array = value as? [Any] { pending.append(contentsOf: array) }
        }
        var result: [Int: Int] = [:]
        for row in rows {
            guard let anchor = row.anchor,
                  anchor.fileID == "Session.swift" || anchor.fileID.hasSuffix("/Session.swift") else { continue }
            guard anchor.line > 0, anchor.line <= starts.count, anchor.column > 0 else {
                throw EvaluationError.invalidResult("Invalid compiler source anchor for inline results.")
            }
            let point = starts[anchor.line - 1] + anchor.column - 1
            let lineEnd = anchor.line < starts.count ? starts[anchor.line] : bytes.count
            let matches = ranges.filter { $0.contains(point) }
            guard point < lineEnd,
                  let outer = matches.max(by: { $0.count < $1.count }),
                  matches.allSatisfy({ outer.lowerBound <= $0.lowerBound && outer.upperBound >= $0.upperBound }) else {
                throw EvaluationError.invalidResult("No complete Swift expression for source \(row.label).")
            }
            result[row.sourceID] = starts.prefix { $0 <= outer.upperBound }.count
        }
        return result
    }
}
