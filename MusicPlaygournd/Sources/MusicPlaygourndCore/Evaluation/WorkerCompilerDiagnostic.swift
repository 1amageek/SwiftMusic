import Foundation
import SwiftMusic

/// Bounded compiler provenance emitted by an evaluation worker before ready.
public struct WorkerCompilerDiagnostic: Codable, Sendable, Equatable {
    public static let stderrPrefix = "SWIFTMUSIC_COMPILER_DIAGNOSTIC:"

    public let revision: UInt64
    public let domain: String
    public let message: String
    public let fileID: String
    public let line: Int
    public let column: Int
    public let utf8Offset: Int?
    public let patternText: String?

    public init(revision: UInt64, error: LocatedSoundCompilationError) throws {
        guard error.anchor.fileID.utf8.count <= 256,
              error.anchor.line > 0, error.anchor.column > 0,
              error.anchor.line <= 65_536, error.anchor.column <= 65_536,
              error.utf8Offset == nil || (error.utf8Offset! >= 0 && error.utf8Offset! <= 65_536),
              error.patternText?.utf8.count ?? 0 <= 65_536 else {
            throw EvaluationError.invalidResult("Compiler diagnostic provenance is out of bounds.")
        }
        self.revision = revision
        self.domain = Self.domain(for: error.underlying)
        self.message = String(describing: error.underlying)
        self.fileID = error.anchor.fileID
        self.line = error.anchor.line
        self.column = error.anchor.column
        self.utf8Offset = error.utf8Offset
        self.patternText = error.patternText
    }

    public func encodedStderrLine() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 else {
            throw EvaluationError.invalidResult("Compiler diagnostic exceeds its bound.")
        }
        return Data((Self.stderrPrefix + data.base64EncodedString() + "\n").utf8)
    }

    public static func decode(from stderr: Data) -> Self? {
        guard let text = String(data: stderr, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(stderrPrefix) else { continue }
            let encoded = String(line.dropFirst(stderrPrefix.count))
            guard let data = Data(base64Encoded: encoded), data.count <= 64 * 1024 else { continue }
            do { return try PropertyListDecoder().decode(Self.self, from: data) }
            catch { continue }
        }
        return nil
    }

    private static func domain(for error: SoundCompilationError) -> String {
        switch error {
        case .invalidRhythm: "rhythm"
        case .invalidNotes: "notes"
        case .invalidGainPattern: "gain"
        case .invalidPanPattern: "pan"
        case .invalidPitchPattern: "pitch"
        case .invalidCutoffPattern: "cutoff"
        case .invalidEnvelopePattern: "envelope"
        case .invalidSampleSelection, .unknownSampleKey: "sampleSelection"
        default: "compiler"
        }
    }
}
