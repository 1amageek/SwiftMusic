import AppKit
import MusicPlaygourndCore
import SwiftUI

struct EditorDocumentState: Equatable {
    var selection = NSRange(location: 0, length: 0)
    var scrollOffset: CGFloat = 0
    var horizontalScrollOffset: CGFloat = 0
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let inlineLoop: PreparedLoop?
    let inlineEnabled: Bool
    let resultLines: [Int: Int]
    let beatPosition: Double
    let isPlaying: Bool
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
    var selectionRange: NSRange? = nil
    var visualization: PreparedControlVisualization? = nil
    var documentID: UUID? = nil
    var editorState = EditorDocumentState()
    var openDocumentIDs: Set<UUID> = []
    var onEditorStateChange: (UUID, EditorDocumentState) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func viewportRect(_ glyphRect: CGRect, editor: NSTextView, scroll: NSScrollView) -> CGRect {
        let documentRect = glyphRect.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let clipRect = editor.convert(documentRect, to: scroll.contentView)
        return clipRect.offsetBy(dx: -scroll.contentView.bounds.minX, dy: -scroll.contentView.bounds.minY)
    }

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
        context.coordinator.installDocument(documentID, editor: editor, state: editorState)
        editor.string = text
        context.coordinator.restoreSelection(editorState.selection, in: editor)
        editor.delegate = context.coordinator
        context.coordinator.inlineLayout = InlineRhythmLayout(editor: editor)
        editor.setAccessibilityIdentifier("swift-source-editor")
        editor.setAccessibilityLabel("Swift source code")
        scroll.documentView = editor
        context.coordinator.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        editor.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.inlineLayout?.layoutCards()
            coordinator?.publishLayout()
        }
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
        context.coordinator.pruneUndoManagers(keeping: openDocumentIDs)
        guard let editor = scroll.documentView as? NSTextView else { return }
        if context.coordinator.documentID != documentID {
            context.coordinator.switchDocument(to: documentID, text: text, editor: editor, scroll: scroll, state: editorState)
        }
        if editor.string != text {
            context.coordinator.cancelCompletion()
            context.coordinator.replaceText(text, in: editor)
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
        context.coordinator.inlineLayout?.update(loop: inlineLoop, rowLines: resultLines, enabled: inlineEnabled, beat: beatPosition, isPlaying: isPlaying, visualization: visualization)
        context.coordinator.publishLayout()
        context.coordinator.highlightPlayback(editor)
        if context.coordinator.lastSelection != selectionToken, let range = selectionRange {
            context.coordinator.lastSelection = selectionToken
            let count = (editor.string as NSString).length
            guard range.location >= 0, range.location <= count, range.length >= 0, range.length <= count - range.location else { return }
            editor.setSelectedRange(range)
            editor.scrollRangeToVisible(range)
            editor.window?.makeFirstResponder(editor)
        } else if context.coordinator.lastSelection != selectionToken, let selectionLine {
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
        var inlineLayout: InlineRhythmLayout?
        private var published: [Int: CGRect] = [:]
        private var rangeSource = ""
        private var rangeLines: [Int: Int] = [:]
        private var rangePatterns: [Int: String] = [:]
        private var literalRanges: [Int: [NSRange]] = [:]
        private var completionTask: Task<Void, Never>?
        private var completionGeneration = 0
        private var previousActive: [Int: Set<Int>] = [:]
        private(set) var documentID: UUID?
        private var undoManagers: [UUID: UndoManager] = [:]
        private let untitledUndoManager = UndoManager()

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
        @objc func scrolled() {
            inlineLayout?.layoutCards()
            publishEditorState()
            publishLayout()
        }

        func installDocument(_ id: UUID?, editor: CompletionTextView, state: EditorDocumentState) {
            documentID = id
            editor.useUndoManager(undoManager(for: id))
        }

        func switchDocument(to id: UUID?, text: String, editor: NSTextView, scroll: NSScrollView, state: EditorDocumentState) {
            publishEditorState()
            cancelCompletion()
            if let editor = editor as? CompletionTextView {
                editor.dismissCompletions()
                editor.breakUndoCoalescing()
                editor.useUndoManager(undoManager(for: id))
            }
            documentID = id
            lastSelection = 0
            lastScrollDelta = parent.scrollDelta
            previousActive = [:]
            rangeSource = ""
            rangeLines = [:]
            rangePatterns = [:]
            published = [:]
            replaceText(text, in: editor)
            highlight(editor)
            restoreSelection(state.selection, in: editor)
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: max(0, state.horizontalScrollOffset), y: max(0, state.scrollOffset)))
            scroll.reflectScrolledClipView(clip)
        }

        func replaceText(_ text: String, in editor: NSTextView) {
            let undo = editor.undoManager
            undo?.disableUndoRegistration()
            editor.string = text
            undo?.enableUndoRegistration()
        }

        func restoreSelection(_ selection: NSRange, in editor: NSTextView) {
            let length = (editor.string as NSString).length
            guard selection.location >= 0, selection.location <= length,
                  selection.length >= 0, selection.length <= length - selection.location else {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                return
            }
            editor.setSelectedRange(selection)
        }

        private func undoManager(for id: UUID?) -> UndoManager {
            guard let id else { return untitledUndoManager }
            if let manager = undoManagers[id] { return manager }
            let manager = UndoManager()
            undoManagers[id] = manager
            return manager
        }

        func pruneUndoManagers(keeping ids: Set<UUID>) {
            guard !ids.isEmpty else { return }
            undoManagers = undoManagers.filter { ids.contains($0.key) }
        }

        private func publishEditorState() {
            guard let scroll, let editor = scroll.documentView as? NSTextView, let id = documentID else { return }
            parent.onEditorStateChange(id, EditorDocumentState(selection: editor.selectedRange(), scrollOffset: scroll.contentView.bounds.minY, horizontalScrollOffset: scroll.contentView.bounds.minX))
        }
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
                    rectangles[line] = CodeEditor.viewportRect(rect, editor: editor, scroll: scroll)
                }
                offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
                line += 1
            }
            guard rectangles != published else { return }
            published = rectangles
            let identity = documentID
            Task { @MainActor [weak self] in
                guard let self, self.documentID == identity, self.published == rectangles else { return }
                self.parent.onLayout(rectangles)
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let replacementString { parent.beforeEdit(affectedCharRange, replacementString) }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) { publishEditorState() }
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
            let identity = documentID
            guard selection.length == 0 else { return }
            completionTask = Task { @MainActor [weak self, weak editor] in
                do {
                    if !immediate { try await Task.sleep(for: .milliseconds(250)) }
                    guard let self, let editor, self.documentID == identity else { return }
                    self.parent.onCompletionStatus("Swift completion…")
                    let values = try await self.parent.completions(source, selection.location)
                    try Task.checkCancellation()
                    guard generation == self.completionGeneration, self.documentID == identity else { return }
                    guard editor.string == source, editor.selectedRange() == selection else {
                        self.parent.onCompletionStatus("")
                        return
                    }
                    self.parent.onCompletionStatus(values.isEmpty ? "No Swift completions" : "")
                    editor.presentCompletions(values, source: source, selection: selection)
                } catch is CancellationError {
                    // A later source/cursor request owns completion presentation.
                } catch {
                    guard let self, generation == self.completionGeneration, self.documentID == identity else { return }
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
