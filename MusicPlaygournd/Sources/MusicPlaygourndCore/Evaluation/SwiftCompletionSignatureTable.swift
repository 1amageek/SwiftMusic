import Foundation

/// The bounded, versioned annotations for SwiftMusic declarations.
public enum SwiftCompletionSignatureTable {
    private static let entries: [SwiftCompletionSemanticKey: CompletionAnnotation] = {
        let signatures = [
            ("gain(value: Double)", "ModifiedSound", CompletionAnnotation(unit: "amplitude", minimum: 0, maximum: 2, scale: "linear")),
            ("pan(value: Double)", "ModifiedSound", CompletionAnnotation(unit: "pan", minimum: -1, maximum: 1, scale: "linear")),
            ("transpose(semitones: Int)", "ModifiedSound", CompletionAnnotation(unit: "semitones", minimum: -12, maximum: 12, scale: "linear")),
            ("lowPass(cutoff: Frequency)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic")),
            ("lowPass(cutoff: Frequency, resonanceQ: Double, slope: FilterSlope)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic")),
            ("highPass(cutoff: Frequency)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic")),
            ("highPass(cutoff: Frequency, resonanceQ: Double, slope: FilterSlope)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic")),
            ("bandPass(cutoff: Frequency)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic")),
            ("bandPass(cutoff: Frequency, resonanceQ: Double, slope: FilterSlope)", "ModifiedSound", CompletionAnnotation(unit: "hertz", minimum: 20, maximum: 20_000, scale: "logarithmic"))
        ]
        var result: [SwiftCompletionSemanticKey: CompletionAnnotation] = [:]
        for (label, detail, annotation) in signatures {
            result[SwiftCompletionSemanticKey(label: label, detail: detail, argumentIndex: 0)] = annotation
        }
        return result
    }()

    public static func annotation(for key: SwiftCompletionSemanticKey) -> CompletionAnnotation? {
        entries[key]
    }
}
