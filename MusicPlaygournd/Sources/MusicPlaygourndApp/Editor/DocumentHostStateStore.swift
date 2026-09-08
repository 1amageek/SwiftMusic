import CryptoKit
import Foundation
import MusicPlaygourndCore

/// Persists host settings separately from the Swift document and all audio assets.
struct DocumentHostStateStore: Sendable {
    struct LearnBinding: Codable, Sendable, Equatable {
        let endpoint: MIDIEndpointID
        let channel: Int
        let controller: Int
        let address: LiveControlAddress
        var range: ClosedRange<Double>?
    }

    struct State: Codable, Sendable {
        var adoptedSourceDigest: String?
        var route: MIDISessionRoute
        var effect: HostedAudioUnitState?
        var effectBypassed: Bool
        var bindings: [LearnBinding]

        func validate() throws {
            guard bindings.count <= DocumentHostStateStore.maximumBindingCount else { throw Failure.tooLarge }
            try route.validate()
            for endpoint in route.inputIDs.union(route.output.map { [$0] } ?? []) {
                _ = try MIDIEndpointID(rawValue: endpoint.rawValue)
            }
            if let adoptedSourceDigest {
                guard adoptedSourceDigest.count == 64,
                      adoptedSourceDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw Failure.invalidState("Invalid adopted source digest")
                }
            }
            guard bindings.isEmpty || adoptedSourceDigest != nil else {
                throw Failure.invalidState("Learn bindings require adopted source identity")
            }
            var keys = Set<String>()
            for binding in bindings {
                _ = try MIDIEndpointID(rawValue: binding.endpoint.rawValue)
                _ = try MIDIMessage.controlChange(channel: binding.channel, controller: binding.controller, value: 0).validated()
                guard keys.insert("\(binding.endpoint.rawValue):\(binding.channel):\(binding.controller)").inserted else {
                    throw Failure.invalidState("Duplicate MIDI Learn binding")
                }
                if let range = binding.range {
                    guard range.lowerBound.isFinite, range.upperBound.isFinite, range.lowerBound < range.upperBound else {
                        throw Failure.invalidState("Invalid MIDI Learn range")
                    }
                }
            }
            guard effect != nil || !effectBypassed else {
                throw Failure.invalidState("Bypass requires an effect")
            }
        }
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidDocument
        case invalidState(String)
        case tooLarge
        case identityMismatch

        var errorDescription: String? {
            switch self {
            case .invalidDocument: "Host settings require a local Swift document."
            case .invalidState(let message): "Invalid host settings: \(message)"
            case .tooLarge: "Host settings exceed 1 MiB."
            case .identityMismatch: "Host settings belong to another document."
            }
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let canonicalDocument: String
        let documentDigest: String
        let state: State
    }

    static let maximumBytes = 1_048_576
    static let maximumBindingCount = maximumBytes / MemoryLayout<LearnBinding>.stride
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "MusicPlaygournd/HostState")) {
        self.directory = directory
    }

    static func sourceDigest(_ source: String) -> String { digest(source) }

    func save(_ state: State, for document: URL) throws {
        try state.validate()
        let identity = try canonicalIdentity(document)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(version: 1, canonicalDocument: identity,
            documentDigest: Self.digest(identity), state: state))
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: location(identity), options: .atomic)
    }

    func load(for document: URL) throws -> State? {
        let identity = try canonicalIdentity(document)
        let file = location(identity)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
            try handle.close()
        } catch {
            let original = error
            do { try handle.close() }
            catch { throw Failure.invalidState("Reading host settings failed: \(original); closing also failed: \(error)") }
            throw original
        }
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        guard data.starts(with: Data("bplist00".utf8)) else {
            throw Failure.invalidState("Expected a binary property list")
        }
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw Failure.invalidState("Unsupported version") }
        guard envelope.canonicalDocument == identity, envelope.documentDigest == Self.digest(identity) else {
            throw Failure.identityMismatch
        }
        try envelope.state.validate()
        return envelope.state
    }

    func fileURL(for document: URL) throws -> URL { location(try canonicalIdentity(document)) }

    private func canonicalIdentity(_ document: URL) throws -> String {
        guard document.isFileURL, !document.hasDirectoryPath else { throw Failure.invalidDocument }
        let canonical = document.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw Failure.invalidDocument
        }
        return canonical.absoluteString
    }

    private func location(_ identity: String) -> URL {
        directory.appending(path: Self.digest(identity) + ".plist")
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
