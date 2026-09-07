import Foundation
import XCTest
@testable import MusicPlaygourndCore

final class SwiftCompletionServiceTests: XCTestCase {
    func testSnippetSelectionAndMalformedEdits() throws {
        let decoded = try SwiftCompletionService.decodeSnippet("gain(${1:value}, cycle: ${2:cycle})$0", enabled: true)
        XCTAssertEqual(decoded.0, "gain(value, cycle: cycle)")
        XCTAssertEqual(decoded.1, NSRange(location: 5, length: 5))
        XCTAssertThrowsError(try SwiftCompletionService.decodeSnippet("${1|one,two|}", enabled: true))
        let invalid: [String: Any] = ["items": [["label": "gain", "textEdit": [
            "range": ["start": ["line": 99, "character": 0], "end": ["line": 99, "character": 1]], "newText": "gain(1)"
        ]]]]
        let data = try JSONSerialization.data(withJSONObject: invalid)
        XCTAssertThrowsError(try SwiftCompletionService.decode(data, source: "sample.ga", cursor: 9))
    }

    func testRealSwiftMusicOverloadsUnicodeEditsAndShutdown() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workspace = FileManager.default.temporaryDirectory.appending(path: "SwiftCompletionService-\(UUID().uuidString)")
        let executable = try XCTUnwrap(SwiftCompletionConnectionTests.resolveSourceKitLSP())
        let service = SwiftCompletionService(packageURL: package, workspace: workspace, sourceKitLSPExecutable: executable)
        do {
            let source = "// 🎵\nstruct Session: Music {\n var body: some Sound {\n Sample(\"kick\").ga\n }\n}"
            let cursor = NSMaxRange((source as NSString).range(of: ".ga"))
            let initial = Task { try await service.completions(source: source, utf16Offset: cursor) }
            try await Task.sleep(for: .milliseconds(100))
            initial.cancel()
            let gains = try await service.completions(source: source, utf16Offset: cursor)
            do { _ = try await initial.value; XCTFail("Cancelled initialization requester must not deliver candidates") }
            catch is CancellationError { }
            XCTAssertTrue(gains.contains { $0.label.contains("gain") && $0.label.contains("Double") })
            XCTAssertTrue(gains.contains { $0.label.contains("gain") && $0.label.contains("GainPattern") })
            let gain = try XCTUnwrap(gains.first { $0.label.contains("gain") && $0.label.contains("Double") })
            XCTAssertEqual((source as NSString).substring(with: gain.replacementRange), "ga")
            XCTAssertTrue(gain.insertion.hasPrefix("gain("))
            XCTAssertNotNil(gain.selectionRange)
            let rhythmSource = source.replacingOccurrences(of: ".ga", with: ".rh")
            let rhythms = try await service.completions(source: rhythmSource, utf16Offset: cursor)
            XCTAssertTrue(rhythms.contains { $0.label.contains("rhythm") })
            let old = Task { try await service.completions(source: source, utf16Offset: cursor) }
            old.cancel()
            do { _ = try await old.value; XCTFail("Cancelled completion must not be delivered") }
            catch is CancellationError { }
            let recovered = try await service.completions(source: rhythmSource, utf16Offset: cursor)
            XCTAssertTrue(recovered.contains { $0.label.contains("rhythm") })
            try await service.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        } catch {
            try await service.shutdown()
            throw error
        }
    }
}
