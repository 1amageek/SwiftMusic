import AppKit
import SwiftUI
import Testing
@testable import MusicPlaygourndApp

extension NativeHostTests {
    @MainActor
    struct EditorTabsIntegrationTests {
        @Test(.timeLimit(.minutes(2)))
        func productionEditorKeepsTwoDirtyTabsAndTheirUndo() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
            let a = root.appending(path: "A.swift"), b = root.appending(path: "B.swift")
            try "// A\n".write(to: a, atomically: true, encoding: .utf8)
            try "// B\n".write(to: b, atomically: true, encoding: .utf8)
            let model = SessionModel()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 540),
                styleMask: [.titled], backing: .buffered, defer: false)
            let hosting = NSHostingView(rootView: ContentView(model: model))
            window.contentView = hosting
            do {
                try model.openDocument(at: a)
                try await settle(hosting)
                let first = model.activeDocument
                let editor = try #require(findEditor(hosting))
                window.makeFirstResponder(editor)
                editor.insertText("// Edited A\n", replacementRange: NSRange(location: 0, length: 0))
                editor.breakUndoCoalescing()
                #expect(first.source == "// Edited A\n// A\n" && first.isDirty)
                try model.openDocument(at: b)
                try await settle(hosting)
                #expect(findEditor(hosting) === editor)
                #expect(editor.string == "// B\n")
                let second = model.activeDocument
                editor.insertText("// Edited B\n", replacementRange: NSRange(location: 0, length: 0))
                editor.breakUndoCoalescing()
                model.selectDocument(first.id)
                try await settle(hosting)
                #expect(editor.string == "// Edited A\n// A\n")
                try #require(editor.undoManager).undo()
                #expect(editor.string == "// A\n")
                #expect(first.source == "// A\n" && second.source == "// Edited B\n// B\n")
                model.selectDocument(second.id)
                try await settle(hosting)
                #expect(editor.string == "// Edited B\n// B\n")
                try #require(editor.undoManager).undo()
                #expect(editor.string == "// B\n" && second.source == "// B\n")
                #expect(!model.closeDocument(first.id, decision: .cancel))
                #expect(model.documents.count == 3)
                #expect(model.saveDocument())
                #expect(try String(contentsOf: b, encoding: .utf8) == "// B\n")
                window.contentView = nil
                try await model.shutdown()
            } catch {
                window.contentView = nil
                try await model.shutdown()
                throw error
            }
        }

        private func settle(_ view: NSView) async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }

        private func findEditor(_ view: NSView) -> CompletionTextView? {
            if let editor = view as? CompletionTextView { return editor }
            for child in view.subviews {
                if let editor = findEditor(child) { return editor }
            }
            return nil
        }
    }
}
