import AppKit
import MusicPlaygourndCore
import SwiftUI

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let selectionLine: Int?
    let selectionToken: Int
    let rhythmLines: [Int]
    let rowLines: [Int: Int]
    let patternTexts: [Int: String]
    let activeTokens: [Int: Set<Int>]
    let scrollDelta: CGFloat
    let onLayout: ([Int: CGRect]) -> Void
    let beforeEdit: (NSRange, String) -> Void
    let onEdit: () -> Void
    let completions: @MainActor (String, Int) async throws -> [SwiftCompletion]
    let onCompletionStatus: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = CompletionTextView()
        editor.isRichText = false
        editor.allowsUndo = true
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        editor.defaultParagraphStyle = paragraph
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
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        editor.onLayout = { [weak coordinator = context.coordinator] in coordinator?.publishLayout() }
        editor.onCompletionRequest = { [weak coordinator = context.coordinator, weak editor] in
            guard let editor else { return }
            coordinator?.requestCompletion(editor, immediate: true)
        }
        context.coordinator.highlight(editor)
        context.coordinator.publishLayout()
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelCompletion()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text {
            context.coordinator.cancelCompletion()
            editor.string = text
            context.coordinator.highlight(editor)
        }
        let delta = scrollDelta - context.coordinator.lastScrollDelta
        if delta != 0 {
            context.coordinator.lastScrollDelta = scrollDelta
            let clip = scroll.contentView
            let y = min(max(0, clip.bounds.minY - delta), max(0, editor.bounds.height - clip.bounds.height))
            clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        context.coordinator.publishLayout()
        context.coordinator.highlightPlayback(editor)
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
        var lastScrollDelta: CGFloat = 0
        weak var scroll: NSScrollView?
        private var published: [Int: CGRect] = [:]
        private var rangeSource = ""
        private var rangeLines: [Int: Int] = [:]
        private var rangePatterns: [Int: String] = [:]
        private var literalRanges: [Int: [NSRange]] = [:]
        private var completionTask: Task<Void, Never>?
        private var completionGeneration = 0
        private var previousActive: [Int: Set<Int>] = [:]

        func highlightPlayback(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let text = editor.string as NSString
            let changed = rangeSource != editor.string || rangeLines != parent.rowLines || rangePatterns != parent.patternTexts
            guard changed || previousActive != parent.activeTokens else { return }
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
            if changed {
                rangeSource = editor.string
                rangeLines = parent.rowLines
                rangePatterns = parent.patternTexts
                literalRanges = [:]
                for (id, pattern) in parent.patternTexts {
                    guard let line = parent.rowLines[id] else { continue }
                    literalRanges[id] = PlayingLiteral.tokenRanges(pattern: pattern, line: line, source: editor.string)
                }
            }
            previousActive = parent.activeTokens
            for (id, ranges) in literalRanges {
                for (index, range) in ranges.enumerated() {
                    let active = parent.activeTokens[id]?.contains(index) == true
                    layout.addTemporaryAttributes([
                        .backgroundColor: NSColor.systemMint.withAlphaComponent(active ? 0.9 : 0.04),
                        .foregroundColor: active ? NSColor.black : NSColor.systemMint
                    ], forCharacterRange: range)
                }
            }
        }
        @objc func scrolled() { publishLayout() }
        func publishLayout() {
            guard let scroll, let editor = scroll.documentView as? NSTextView,
                  let layout = editor.layoutManager, let container = editor.textContainer else { return }
            layout.ensureLayout(for: container)
            let text = editor.string as NSString
            let requested = Set(parent.rhythmLines)
            var rectangles: [Int: CGRect] = [:]
            var offset = 0
            var line = 1
            while offset < text.length {
                if requested.contains(line) {
                    let glyph = layout.glyphIndexForCharacter(at: offset)
                    let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    rectangles[line] = CGRect(x: 0, y: rect.minY + editor.textContainerOrigin.y - scroll.contentView.bounds.minY, width: 0, height: rect.height)
                }
                offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
                line += 1
            }
            guard rectangles != published else { return }
            published = rectangles
            Task { @MainActor [weak self] in
                guard let self, self.published == rectangles else { return }
                self.parent.onLayout(rectangles)
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString { parent.beforeEdit(affectedCharRange, replacementString) }
            return true
        }
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, parent.text != editor.string else { return }
            parent.text = editor.string
            highlight(editor)
            parent.onEdit()
            publishLayout()
            guard let editor = editor as? CompletionTextView else { return }
            let offset = editor.selectedRange().location
            let text = editor.string as NSString
            guard editor.selectedRange().length == 0, offset > 0, offset <= text.length else {
                completionTask?.cancel()
                return
            }
            let last = text.character(at: offset - 1)
            if last == 46 || (65...90).contains(last) || (97...122).contains(last) || last == 95 {
                requestCompletion(editor, immediate: last == 46)
            } else {
                completionTask?.cancel()
                parent.onCompletionStatus("")
            }
        }

        func requestCompletion(_ editor: CompletionTextView, immediate: Bool) {
            completionTask?.cancel()
            completionGeneration += 1
            let generation = completionGeneration
            let source = editor.string
            let selection = editor.selectedRange()
            guard selection.length == 0 else { return }
            completionTask = Task { @MainActor [weak self, weak editor] in
                do {
                    if !immediate { try await Task.sleep(for: .milliseconds(250)) }
                    guard let self, let editor else { return }
                    self.parent.onCompletionStatus("Swift completion…")
                    let values = try await self.parent.completions(source, selection.location)
                    try Task.checkCancellation()
                    guard generation == self.completionGeneration else { return }
                    guard editor.string == source, editor.selectedRange() == selection else {
                        self.parent.onCompletionStatus("")
                        return
                    }
                    self.parent.onCompletionStatus(values.isEmpty ? "No Swift completions" : "")
                    editor.presentCompletions(values, source: source, selection: selection)
                } catch is CancellationError {
                    // A later source/cursor request owns completion presentation.
                } catch {
                    guard let self, generation == self.completionGeneration else { return }
                    self.parent.onCompletionStatus("Completion: \(error.localizedDescription)")
                }
            }
        }

        func cancelCompletion() {
            completionTask?.cancel()
            completionGeneration += 1
            parent.onCompletionStatus("")
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
