import AppKit
import MusicPlaygourndCore
import Testing
@testable import MusicPlaygourndApp

extension NativeHostTests {
    @MainActor
    struct CompletionEditorTests {
        @Test(.timeLimit(.minutes(3)))
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
                selectionRange: NSRange(location: 5, length: 3),
                annotation: CompletionAnnotation(unit: "amplitude", minimum: 0, maximum: 2))
            editor.presentCompletions([item], source: original, selection: editor.selectedRange())
            let cell = try #require(editor.tableView(NSTableView(), viewFor: nil, row: 0) as? NSStackView)
            let labels = cell.arrangedSubviews.compactMap { $0 as? NSTextField }
            #expect(labels.map(\.stringValue) == ["gain(value: Double)", "amplitude 0…2"])
            #expect(labels[1].contentCompressionResistancePriority(for: .horizontal) == .required)
            editor.moveCompletion(by: 1)
            #expect(editor.string == original)
            #expect(observer.changes == 0)
            editor.acceptSelectedCompletion()
            #expect(editor.string == "// 🎵\nSample(\"kick\").gain(0.5)")
            #expect((editor.string as NSString).substring(with: editor.selectedRange()) == "0.5")
            #expect(observer.changes == 1)
            #expect(observer.ranges == [range])
            let undo = try #require(editor.undoManager)
            #expect(undo.canUndo)
            undo.undo()
            #expect(editor.string == original)
        }

        @Test(.timeLimit(.minutes(3)))
        func testStaleCompletionCannotReplaceNewSource() {
            let editor = CompletionTextView()
            editor.string = "value.ga"
            editor.setSelectedRange(NSRange(location: 8, length: 0))
            let item = SwiftCompletion(label: "gain", detail: nil, insertion: "gain(1)",
                replacementRange: NSRange(location: 6, length: 2), selectionRange: nil)
            editor.presentCompletions([item], source: editor.string, selection: editor.selectedRange())
            editor.string = "value.pan"
            editor.acceptSelectedCompletion()
            #expect(editor.string == "value.pan")
        }

        @Test(.timeLimit(.minutes(3)))
        func testControlSpaceRequestsCompletionOnce() throws {
            let editor = CompletionTextView()
            var requests = 0
            editor.onCompletionRequest = { requests += 1 }
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: " ",
                charactersIgnoringModifiers: " ",
                isARepeat: false,
                keyCode: 49
            ))

            editor.keyDown(with: event)

            #expect(requests == 1)
        }

        @Test(.timeLimit(.minutes(3)))
        func testTabAcceptsSelectedCompletionAsOneUndoableEdit() throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            let editor = CompletionTextView(frame: window.contentView!.bounds)
            editor.isRichText = false
            editor.allowsUndo = true
            let observer = EditObserver()
            editor.delegate = observer
            window.contentView = editor
            window.makeFirstResponder(editor)
            let original = "Sample(\"kick\").ga"
            editor.string = original
            editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
            let range = (original as NSString).range(of: "ga", options: .backwards)
            let item = SwiftCompletion(label: "gain(value: Double)", detail: nil,
                insertion: "gain(0.5)", replacementRange: range,
                selectionRange: NSRange(location: 5, length: 3),
                annotation: CompletionAnnotation(unit: "amplitude", minimum: 0, maximum: 2))
            editor.presentCompletions([item], source: original, selection: editor.selectedRange())
            let cell = try #require(editor.tableView(NSTableView(), viewFor: nil, row: 0) as? NSStackView)
            let labels = cell.arrangedSubviews.compactMap { $0 as? NSTextField }
            #expect(labels.map(\.stringValue) == ["gain(value: Double)", "amplitude 0…2"])
            #expect(labels[1].contentCompressionResistancePriority(for: .horizontal) == .required)
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: 48
            ))

            editor.keyDown(with: event)

            #expect(editor.string == "Sample(\"kick\").gain(0.5)")
            #expect(observer.changes == 1)
            let undo = try #require(editor.undoManager)
            #expect(undo.canUndo)
            undo.undo()
            #expect(editor.string == original)
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
}
