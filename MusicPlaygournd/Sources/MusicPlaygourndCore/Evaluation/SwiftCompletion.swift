import Foundation

/// A semantic SourceKit-LSP completion with a document-relative UTF-16 edit.
public struct SwiftCompletion: Sendable, Equatable {
    public let label: String
    public let detail: String?
    public let insertion: String
    public let replacementRange: NSRange
    public let selectionRange: NSRange?

    public init(
        label: String,
        detail: String? = nil,
        insertion: String,
        replacementRange: NSRange,
        selectionRange: NSRange? = nil
    ) {
        self.label = label
        self.detail = detail
        self.insertion = insertion
        self.replacementRange = replacementRange
        self.selectionRange = selectionRange
    }
}
