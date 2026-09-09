import AppKit
import MusicPlaygourndCore

/// Keeps keyboard focus in the editor while presenting semantic candidates.
@MainActor
final class CompletionTextView: NSTextView, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    var onLayout: (() -> Void)?
    var onCompletionRequest: (() -> Void)?
    private var documentUndoManager = UndoManager()
    private var candidates: [SwiftCompletion] = []
    private var candidateSource = ""
    private var candidateSelection = NSRange(location: 0, length: 0)
    private let completionPopover = NSPopover()
    private let completionTable = NSTableView()

    override var undoManager: UndoManager? { documentUndoManager }

    @objc func undo(_ sender: Any?) {
        breakUndoCoalescing()
        documentUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        breakUndoCoalescing()
        documentUndoManager.redo()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return documentUndoManager.canUndo
        case #selector(redo(_:)): return documentUndoManager.canRedo
        default: return super.validateMenuItem(menuItem)
        }
    }

    func useUndoManager(_ manager: UndoManager) { documentUndoManager = manager }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func complete(_ sender: Any?) { onCompletionRequest?() }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           event.charactersIgnoringModifiers == " " {
            complete(nil)
            return
        }
        if !candidates.isEmpty, string == candidateSource, selectedRange() == candidateSelection {
            switch event.keyCode {
            case 125: moveCompletion(by: 1); return
            case 126: moveCompletion(by: -1); return
            case 36, 48: acceptSelectedCompletion(); return
            case 53: dismissCompletions(); return
            default: dismissCompletions()
            }
        } else { dismissCompletions() }
        super.keyDown(with: event)
    }

    func presentCompletions(_ values: [SwiftCompletion], source: String, selection: NSRange) {
        guard string == source, selectedRange() == selection else { return }
        guard !values.isEmpty else { dismissCompletions(); return }
        candidates = values
        candidateSource = source
        candidateSelection = selection
        if completionTable.tableColumns.isEmpty {
            completionTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("signature")))
            completionTable.headerView = nil
            completionTable.rowHeight = 25
            completionTable.dataSource = self
            completionTable.delegate = self
            completionTable.target = self
            completionTable.action = #selector(chooseCompletion)
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.documentView = completionTable
            let controller = NSViewController()
            controller.view = scroll
            completionPopover.contentViewController = controller
            completionPopover.behavior = .semitransient
            completionPopover.animates = false
            completionPopover.delegate = self
        }
        completionTable.reloadData()
        completionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let width = min(560, max(300, values.map { CGFloat($0.label.count) * 8 + 32 }.max() ?? 300))
        completionPopover.contentSize = NSSize(width: width, height: CGFloat(min(values.count, 8)) * 27)
        completionTable.tableColumns[0].width = width - 20
        guard window?.isKeyWindow == true, let window else { return }
        let screenRect = firstRect(forCharacterRange: selection, actualRange: nil)
        let rect = convert(window.convertFromScreen(screenRect), from: nil)
        completionPopover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        window.makeFirstResponder(self)
    }

    func moveCompletion(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let row = min(candidates.count - 1, max(0, completionTable.selectedRow + offset))
        completionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        completionTable.scrollRowToVisible(row)
    }

    @objc private func chooseCompletion() { acceptSelectedCompletion() }

    func acceptSelectedCompletion() {
        let row = completionTable.selectedRow
        guard string == candidateSource, selectedRange() == candidateSelection,
              candidates.indices.contains(row) else { dismissCompletions(); return }
        let candidate = candidates[row]
        dismissCompletions()
        window?.makeFirstResponder(self)
        accept(candidate)
    }

    func dismissCompletions() {
        candidates = []
        completionPopover.close()
    }

    func popoverDidClose(_ notification: Notification) { candidates = [] }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = candidates[row]
        let label = NSTextField(labelWithString: candidate.label)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = candidate.detail
        guard let annotation = candidate.annotation else { return label }
        var text = annotation.unit ?? ""
        if let minimum = annotation.minimum, let maximum = annotation.maximum {
            text += String(format: " %.3g…%.3g", minimum, maximum)
        }
        if annotation.scale == "logarithmic" { text += " log" }
        let detail = NSTextField(labelWithString: text)
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = NSStackView(views: [label, detail])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.toolTip = [candidate.label, text, candidate.detail].compactMap { $0 }.joined(separator: "\n")
        return stack
    }

    func accept(_ candidate: SwiftCompletion) {
        let range = candidate.replacementRange
        let length = (string as NSString).length
        guard range.location >= 0, range.location <= length,
              range.length >= 0, range.length <= length - range.location,
              Range(range, in: string) != nil else { return }
        if let selection = candidate.selectionRange {
            let insertedLength = candidate.insertion.utf16.count
            guard selection.location >= 0, selection.location <= insertedLength,
                  selection.length >= 0, selection.length <= insertedLength - selection.location else { return }
        }
        insertText(candidate.insertion, replacementRange: range)
        if let selection = candidate.selectionRange {
            setSelectedRange(NSRange(location: range.location + selection.location, length: selection.length))
        }
    }
}
