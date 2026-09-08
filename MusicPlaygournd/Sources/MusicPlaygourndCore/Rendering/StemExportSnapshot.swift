import Foundation

/// The immutable source and live-control identity accepted for one stem export.
public struct StemExportSnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let generation: UInt64
    public let manifest: [StemExportManifest]

    internal init(revision: UInt64, generation: UInt64, manifest: [StemExportManifest]) {
        self.revision = revision
        self.generation = generation
        self.manifest = manifest
    }
}
