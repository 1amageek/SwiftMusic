import AppKit
import SwiftUI
import MusicPlaygourndCore
import Testing
@testable import MusicPlaygourndApp

extension NativeHostTests {
@MainActor
struct CodeEditorDocumentTests {
    @Test(.timeLimit(.minutes(1)))
    func editsAndUndoRemainIsolatedAcrossDocuments() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        let editor = CompletionTextView(frame: window.contentView!.bounds)
        editor.isRichText = false
        editor.allowsUndo = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        let first = UndoManager()
        let second = UndoManager()

        editor.useUndoManager(first)
        editor.string = "first"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" A", replacementRange: editor.selectedRange())
        #expect(editor.string == "first A")
        #expect(editor.undoManager === first)

        editor.useUndoManager(second)
        editor.string = "second"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" B", replacementRange: editor.selectedRange())
        #expect(editor.string == "second B")
        #expect(editor.undoManager === second)
        second.undo()
        #expect(editor.string == "second")

        editor.string = "first A"
        editor.useUndoManager(first)
        first.undo()
        #expect(editor.string == "first")
    }

    @Test(.timeLimit(.minutes(1)))
    func switchingRestoresBothScrollAxes() {
        let first = UUID(), second = UUID()
        let view = makeCodeEditor(documentID: first, completions: { _, _ in [] }, onCompletionStatus: { _ in })
        let coordinator = view.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))
        let editor = CompletionTextView(frame: NSRect(x: 0, y: 0, width: 1500, height: 1500))
        editor.isRichText = false
        scroll.documentView = editor
        coordinator.scroll = scroll
        coordinator.installDocument(first, editor: editor, state: .init())
        scroll.contentView.scroll(to: CGPoint(x: 160, y: 250))
        coordinator.switchDocument(to: second, text: "B", editor: editor, scroll: scroll,
            state: EditorDocumentState(scrollOffset: 80, horizontalScrollOffset: 45))
        #expect(scroll.contentView.bounds.origin == CGPoint(x: 45, y: 80))
        coordinator.switchDocument(to: first, text: "A", editor: editor, scroll: scroll,
            state: EditorDocumentState(scrollOffset: 250, horizontalScrollOffset: 160))
        #expect(scroll.contentView.bounds.origin == CGPoint(x: 160, y: 250))
    }

    @Test(.timeLimit(.minutes(1)))
    func completionFromPreviousDocumentCannotPublishForSameText() async {
        let firstID = UUID()
        let secondID = UUID()
        var release: CheckedContinuation<[SwiftCompletion], Never>?
        var started = false
        var statuses: [String] = []
        let first = makeCodeEditor(documentID: firstID, completions: { _, _ in
            started = true
            return await withCheckedContinuation { continuation in release = continuation }
        }, onCompletionStatus: { statuses.append($0) })
        let second = makeCodeEditor(documentID: secondID, completions: { _, _ in [] }, onCompletionStatus: { statuses.append($0) })
        let coordinator = first.makeCoordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let editor = CompletionTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.string = "value.ga"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        scroll.documentView = editor
        coordinator.scroll = scroll
        coordinator.installDocument(firstID, editor: editor, state: .init())
        coordinator.requestCompletion(editor, immediate: true)
        for _ in 0..<100 where !started { await Task.yield() }
        #expect(started)

        coordinator.parent = second
        coordinator.switchDocument(to: secondID, text: "value.ga", editor: editor, scroll: scroll, state: .init())
        release?.resume(returning: [])
        release = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(!statuses.contains("No Swift completions"))
    }

    private func makeCodeEditor(
        documentID: UUID,
        completions: @escaping @MainActor (String, Int) async throws -> [SwiftCompletion],
        onCompletionStatus: @escaping (String) -> Void
    ) -> CodeEditor {
        CodeEditor(text: .constant("value.ga"), inlineLoop: nil, inlineEnabled: false,
            resultLines: [:], beatPosition: 0, isPlaying: false, selectionLine: nil,
            selectionToken: 0, rhythmLines: [], rowLines: [:], patternTexts: [:], activeTokens: [:],
            scrollDelta: 0, onLayout: { _ in }, beforeEdit: { _, _ in }, onEdit: {},
            completions: completions, onCompletionStatus: onCompletionStatus, documentID: documentID)
    }
}

}
