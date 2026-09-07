import SwiftMusic

/// Visual metadata and a pre-mix peak envelope for one compiled source.
public struct LoopRow: Codable, Sendable, Equatable {
    public let sourceID: Int
    public let label: String
    public let anchor: SoundSourceAnchor?
    public let peaks: [Float]
    public let patternText: String?
    public let resultLine: Int?

    public init(
        sourceID: Int,
        label: String,
        anchor: SoundSourceAnchor?,
        peaks: [Float],
        patternText: String? = nil,
        resultLine: Int? = nil
    ) {
        self.sourceID = sourceID
        self.label = label
        self.anchor = anchor
        self.peaks = peaks
        self.patternText = patternText
        self.resultLine = resultLine
    }
}
