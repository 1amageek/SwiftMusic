import AppKit
import MusicPlaygourndCore
import XCTest
@testable import MusicPlaygourndApp

@MainActor
final class CompletionEditorTests: XCTestCase {
    func testCompletionPreviewIsReadOnlyAndAcceptanceIsOneUndoableEdit() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let editor = CompletionTextView(frame: window.contentView!.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        let observer = EditObserver()
        editor.delegate = observer
        window.contentView = editor
        window.makeFirstResponder(editor)
        let original = "// 🎵\nSample(\"kick\").ga"
        editor.string = original
        editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        let range = (original as NSString).range(of: "ga", options: .backwards)
        let item = SwiftCompletion(label: "gain(value: Double)", detail: nil,
            insertion: "gain(0.5)", replacementRange: range,
            selectionRange: NSRange(location: 5, length: 3))
        editor.presentCompletions([item], source: original, selection: editor.selectedRange())
        editor.moveCompletion(by: 1)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(observer.changes, 0)
        editor.acceptSelectedCompletion()
        XCTAssertEqual(editor.string, "// 🎵\nSample(\"kick\").gain(0.5)")
        XCTAssertEqual((editor.string as NSString).substring(with: editor.selectedRange()), "0.5")
        XCTAssertEqual(observer.changes, 1)
        XCTAssertEqual(observer.ranges, [range])
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(editor.string, original)
    }

    func testStaleCompletionCannotReplaceNewSource() {
        let editor = CompletionTextView()
        editor.string = "value.ga"
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        let item = SwiftCompletion(label: "gain", detail: nil, insertion: "gain(1)",
            replacementRange: NSRange(location: 6, length: 2), selectionRange: nil)
        editor.presentCompletions([item], source: editor.string, selection: editor.selectedRange())
        editor.string = "value.pan"
        editor.acceptSelectedCompletion()
        XCTAssertEqual(editor.string, "value.pan")
    }
    @MainActor private final class EditObserver: NSObject, NSTextViewDelegate {
        var changes = 0
        var ranges: [NSRange] = []
        func textDidChange(_ notification: Notification) { changes += 1 }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            ranges.append(affectedCharRange)
            return true
        }
    }

}
