import Foundation
import Observation

@MainActor @Observable
final class SessionDocument: Identifiable {
    let id = UUID()
    var source: String
    var fileURL: URL?
    var isDirty = false
    var editorState = EditorDocumentState()
    var name: String { fileURL?.lastPathComponent ?? "Untitled.swift" }

    init(source: String, fileURL: URL? = nil) {
        self.source = source
        self.fileURL = fileURL
    }
}
