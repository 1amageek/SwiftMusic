import Foundation
import SwiftMusic
import Testing
@testable import MusicPlaygourndCore

struct ExpressionResultLocationsTests {
    @Test(.timeLimit(.minutes(3)))
    func testMalformedAndMissingExpressionProvenanceFails() throws {
        let row = LoopRow(sourceID: 0, label: "Bass",
            anchor: SoundSourceAnchor(fileID: "Session.swift", line: 1, column: 1), peaks: [])
        #expect(throws: (any Error).self) { try ExpressionResultLocations.lines(ast: Data("{}".utf8), source: "sample()", prefixBytes: 0, rows: [row]) }
        #expect(throws: (any Error).self) { try ExpressionResultLocations.lines(ast: Data("{\"_kind\":\"source_file\"}".utf8), source: "sample()", prefixBytes: 0, rows: [row]) }
    }

    @Test(.timeLimit(.minutes(3)))
    func testPatternAndResultAnchorsMoveIndependently() {
        let source = ".notes(\"C2\")\n.transpose(12)\n.gain(0.4)\n"
        var map = SourceLineMap(source: source, lines: [1, 3])
        let removed = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
        map.applyEdit(range: removed, replacement: "")
        let changed = (source as NSString).replacingCharacters(in: removed, with: "")
        #expect(map.currentLine(for: 1, in: changed) == nil)
        #expect(map.currentLine(for: 3, in: changed) == 2)
    }
}
