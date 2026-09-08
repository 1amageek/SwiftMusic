import Foundation
import SwiftMusic

/// Immutable, bounded semantic information retained with one adopted evaluation.
public struct EditorSemanticMetadata: Codable, Sendable, Equatable, Hashable {
    internal static let empty = EditorSemanticMetadata(uncheckedRevision: 0)

    public struct SampleBank: Codable, Sendable, Equatable, Hashable {
        public let sourceID: Int
        public let displayName: String
        public let values: [String]

        public init(sourceID: Int, displayName: String, values: [String]) throws {
            guard sourceID >= 0, !displayName.isEmpty, displayName.utf8.count <= 256,
                  !values.isEmpty, values.count <= 1_024 else {
                throw EvaluationError.invalidResult("Invalid sample-bank metadata.")
            }
            var identities = Set<String>()
            for value in values {
                guard !value.isEmpty, value.utf8.count <= 256,
                      identities.insert(value).inserted else {
                    throw EvaluationError.invalidResult("Invalid sample-bank value metadata.")
                }
            }
            self.sourceID = sourceID
            self.displayName = displayName
            self.values = values
        }

        private enum CodingKeys: String, CodingKey {
            case sourceID
            case displayName
            case values
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                sourceID: container.decode(Int.self, forKey: .sourceID),
                displayName: container.decode(String.self, forKey: .displayName),
                values: container.decode([String].self, forKey: .values)
            )
        }
    }

    public struct SampleCompletionSite: Codable, Sendable, Equatable, Hashable {
        public let sourceID: Int
        public let contentRange: NSRange
        public let values: [String]

        public var replacementRange: NSRange { contentRange }

        public init(sourceID: Int, contentRange: NSRange, values: [String]) throws {
            guard sourceID >= 0, contentRange.location >= 0, contentRange.length >= 0,
                  contentRange.location <= 65_536,
                  contentRange.length <= 65_536 - contentRange.location,
                  !values.isEmpty, values.count <= 1_024 else {
                throw EvaluationError.invalidResult("Invalid sample completion site.")
            }
            var identities = Set<String>()
            for value in values {
                guard !value.isEmpty, value.utf8.count <= 256,
                      identities.insert(value).inserted else {
                    throw EvaluationError.invalidResult("Invalid sample completion value.")
                }
            }
            self.sourceID = sourceID
            self.contentRange = contentRange
            self.values = values
        }

        private enum CodingKeys: String, CodingKey {
            case sourceID
            case contentRange
            case values
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                sourceID: container.decode(Int.self, forKey: .sourceID),
                contentRange: container.decode(NSRange.self, forKey: .contentRange),
                values: container.decode([String].self, forKey: .values)
            )
        }
    }

    public let revision: UInt64
    public let sampleBanks: [SampleBank]
    public let completionSites: [SampleCompletionSite]

    public var sampleCompletionSites: [SampleCompletionSite] { completionSites }

    /// Returns compiler-admitted sample values for one adopted source site.
    public func sampleCompletions(sourceID: Int, prefix: String = "") -> [SwiftCompletion] {
        guard let site = completionSites.first(where: { $0.sourceID == sourceID }) else { return [] }
        return site.values.filter { $0.hasPrefix(prefix) }.map { value in
            SwiftCompletion(
                label: value,
                detail: "Sample bank",
                insertion: value,
                replacementRange: site.replacementRange,
                semanticKey: SwiftCompletionSemanticKey(label: value, detail: "Sample bank", argumentIndex: 0)
            )
        }
    }

    public init(
        revision: UInt64,
        sampleBanks: [SampleBank] = [],
        completionSites: [SampleCompletionSite] = []
    ) throws {
        guard sampleBanks.count <= 1_024, completionSites.count <= 1_024 else {
            throw EvaluationError.invalidResult("Editor semantic metadata exceeds its bound.")
        }
        var bankIDs = Set<Int>()
        var totalValues = 0
        for bank in sampleBanks {
            guard bankIDs.insert(bank.sourceID).inserted else {
                throw EvaluationError.invalidResult("Duplicate sample-bank metadata source.")
            }
            totalValues += bank.values.count
        }
        guard totalValues <= 1_024 else {
            throw EvaluationError.invalidResult("Sample metadata exceeds its value bound.")
        }
        var siteIDs = Set<Int>()
        var bankValuesByID = [Int: [String]]()
        for bank in sampleBanks {
            bankValuesByID[bank.sourceID] = bank.values
        }
        var totalSiteValues = 0
        for site in completionSites {
            guard siteIDs.insert(site.sourceID).inserted else {
                throw EvaluationError.invalidResult("Duplicate sample completion site.")
            }
            guard let bankValues = bankValuesByID[site.sourceID],
                  site.values == bankValues else {
                throw EvaluationError.invalidResult("Sample completion site does not match its bank.")
            }
            totalSiteValues += site.values.count
        }
        guard totalSiteValues <= 1_024 else {
            throw EvaluationError.invalidResult("Sample completion metadata exceeds its value bound.")
        }
        self.revision = revision
        self.sampleBanks = sampleBanks
        self.completionSites = completionSites
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case sampleBanks
        case completionSites
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            sampleBanks: container.decode([SampleBank].self, forKey: .sampleBanks),
            completionSites: container.decode([SampleCompletionSite].self, forKey: .completionSites)
        )
    }

    private init(uncheckedRevision revision: UInt64) {
        self.revision = revision
        self.sampleBanks = []
        self.completionSites = []
    }

    /// Builds metadata from compiler-retained descriptors and source anchors.
    public init(sound: CompiledSound, source: String, revision: UInt64) throws {
        var banks: [SampleBank] = []
        var sites: [SampleCompletionSite] = []
        for compiledSource in sound.sources {
            guard case .sampleBank(let bank) = compiledSource.kind else { continue }
            let values = bank.assets.map(\.key)
            let displayName = bank.assets.first?.fileURL.lastPathComponent ?? "Source \(compiledSource.id)"
            banks.append(try SampleBank(sourceID: compiledSource.id, displayName: displayName, values: values))
            if let anchor = compiledSource.sampleSelectionAnchor,
               let pattern = compiledSource.sampleSelectionText,
               let range = SourceAnchorLocations.literalArgument(
                   source: source,
                   fileID: anchor.fileID,
                   line: anchor.line,
                   column: anchor.column,
                   methodNames: ["sampleSelection"],
                   expectedValue: pattern
               )?.contentRange {
                sites.append(try SampleCompletionSite(sourceID: compiledSource.id, contentRange: range, values: values))
            }
        }
        try self.init(revision: revision, sampleBanks: banks, completionSites: sites)
    }
}

/// A bounded presentation hint joined to an exact SourceKit completion candidate.
public struct CompletionAnnotation: Codable, Sendable, Equatable, Hashable {
    public let unit: String?
    public let minimum: Double?
    public let maximum: Double?
    public let scale: String?

    public init(unit: String? = nil, minimum: Double? = nil, maximum: Double? = nil, scale: String? = nil) {
        self.unit = unit
        self.minimum = minimum
        self.maximum = maximum
        self.scale = scale
    }
}

/// Stable identity used to join an editor candidate with a signature-table annotation.
public struct SwiftCompletionSemanticKey: Codable, Sendable, Equatable, Hashable {
    public let label: String
    public let detail: String?
    public let argumentIndex: Int

    public init(label: String, detail: String? = nil, argumentIndex: Int) {
        self.label = label
        self.detail = detail
        self.argumentIndex = argumentIndex
    }
}

/// A compiler-derived UTF-16 diagnostic range in the user document.
public struct SourceDiagnosticRange: Codable, Sendable, Equatable, Hashable {
    public let fileID: String
    public let utf16Range: NSRange
    public let line: Int
    public let column: Int

    public var range: NSRange { utf16Range }

    public init(fileID: String, utf16Range: NSRange, line: Int, column: Int) throws {
        guard !fileID.isEmpty, utf16Range.location >= 0, utf16Range.length >= 0,
              line > 0, column > 0 else {
            throw EvaluationError.invalidResult("Invalid source diagnostic range.")
        }
        self.fileID = fileID
        self.utf16Range = utf16Range
        self.line = line
        self.column = column
    }
}
