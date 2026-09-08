import Foundation

/// A semantic SourceKit-LSP completion with a document-relative UTF-16 edit.
public struct SwiftCompletion: Sendable, Equatable {
    public let label: String
    public let detail: String?
    public let insertion: String
    public let replacementRange: NSRange
    public let selectionRange: NSRange?
    public let annotation: CompletionAnnotation?
    public let semanticKey: SwiftCompletionSemanticKey?

    public init(
        label: String,
        detail: String? = nil,
        insertion: String,
        replacementRange: NSRange,
        selectionRange: NSRange? = nil,
        annotation: CompletionAnnotation? = nil,
        semanticKey: SwiftCompletionSemanticKey? = nil
    ) {
        self.label = label
        self.detail = detail
        self.insertion = insertion
        self.replacementRange = replacementRange
        self.selectionRange = selectionRange
        self.annotation = annotation
        self.semanticKey = semanticKey
    }

    public func annotated(
        with annotation: CompletionAnnotation?,
        semanticKey: SwiftCompletionSemanticKey? = nil
    ) -> Self {
        Self(label: label, detail: detail, insertion: insertion,
             replacementRange: replacementRange, selectionRange: selectionRange,
             annotation: annotation, semanticKey: semanticKey ?? self.semanticKey)
    }
}
