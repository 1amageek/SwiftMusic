/// A compiler failure with the declaration anchor and pattern token offset that caused it.
public struct LocatedSoundCompilationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let underlying: SoundCompilationError
    public let anchor: SoundSourceAnchor
    public let utf8Offset: Int?
    public let patternText: String?

    public init(
        underlying: SoundCompilationError,
        anchor: SoundSourceAnchor,
        utf8Offset: Int?,
        patternText: String? = nil
    ) {
        self.underlying = underlying
        self.anchor = anchor
        self.utf8Offset = utf8Offset
        self.patternText = patternText
    }

    public var description: String {
        var result = String(describing: underlying)
        if let utf8Offset { result += " at UTF-8 offset \(utf8Offset)" }
        result += " (\(anchor.fileID):\(anchor.line):\(anchor.column))"
        return result
    }
}

internal struct _LocatedCompilationFailure: Error {
    let error: Error
    let anchor: SoundSourceAnchor
    let patternText: String?
}
