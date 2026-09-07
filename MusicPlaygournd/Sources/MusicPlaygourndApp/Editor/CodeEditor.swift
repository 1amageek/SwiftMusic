import AppKit
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let selectionLine: Int?
    let selectionToken: Int
    let onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: 100_000, height: 100_000)
        editor.textContainerInset = NSSize(width: 22, height: 20)
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        editor.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.09, alpha: 1)
        editor.insertionPointColor = .systemMint
        editor.selectedTextAttributes = [.backgroundColor: NSColor.systemMint.withAlphaComponent(0.25)]
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityIdentifier("swift-source-editor")
        editor.setAccessibilityLabel("Swift source code")
        scroll.documentView = editor
        context.coordinator.highlight(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            editor.string = text
            context.coordinator.highlight(editor)
        }
        if context.coordinator.lastSelection != selectionToken, let selectionLine {
            context.coordinator.lastSelection = selectionToken
            let lines = editor.string.components(separatedBy: "\n")
            guard selectionLine > 0, selectionLine <= lines.count else { return }
            let offset = lines.prefix(selectionLine - 1).reduce(0) { $0 + $1.utf16.count + 1 }
            let range = NSRange(location: offset, length: lines[selectionLine - 1].utf16.count)
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
            editor.window?.makeFirstResponder(editor)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var lastSelection = 0
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            highlight(editor)
            parent.onEdit()
        }
        func highlight(_ editor: NSTextView) {
            guard let storage = editor.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor(calibratedWhite: 0.88, alpha: 1), range: full)
            // These patterns color text only; SwiftMusic remains the sole owner of musical meaning.
            let rules: [(String, NSColor)] = [
                (#"\b(import|struct|var|some|let|if|else|for|in|try|func|return)\b"#, .systemPink),
                (#"\b(Music|Sound|Track|Sample|Synthesizer|Session)\b"#, .systemTeal),
                (#"\"(?:\\.|[^\"\\])*\""#, .systemOrange),
                (#"//[^\n]*"#, .secondaryLabelColor)
            ]
            for (pattern, color) in rules {
                do {
                    let regex = try NSRegularExpression(pattern: pattern)
                    for match in regex.matches(in: editor.string, range: full) {
                        storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                } catch { assertionFailure("Invalid static syntax-coloring expression: \(error)") }
            }
            storage.endEditing()
        }
    }
}
