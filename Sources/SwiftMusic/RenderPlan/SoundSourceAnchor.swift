/// A source-code location retained by a pattern modifier for editor mapping.
public struct SoundSourceAnchor: Sendable, Equatable, Hashable, Codable {
    public let fileID: String
    public let line: Int
    public let column: Int

    public init(
        fileID: String = #fileID,
        line: Int = #line,
        column: Int = #column
    ) {
        self.fileID = fileID
        self.line = line
        self.column = column
    }
}
