import Foundation

/// A sample source descriptor. Loading and playback belong to a client backend.
public struct Sample: Sound, Sendable, Equatable {
    public typealias Body = Never

    public let name: String
    internal let sourceKind: SourceKind

    public init(_ name: String) {
        self.name = name
        sourceKind = .sample(name)
    }

    public init(file url: URL, rootPitch: Pitch = .middleC) throws {
        guard SampleAsset.isAbsoluteFileURL(url) else {
            throw SampleDescriptorError.invalidFileURL
        }
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        sourceKind = .fileSample(fileURL: url, rootPitch: rootPitch)
    }

    public init(bank: SampleBank) {
        name = bank.firstKey
        sourceKind = .sampleBank(bank)
    }

    public var body: Never {
        fatalError("Sample is a compiler terminal")
    }
}

extension Sample: _SoundPrimitive {
    internal var _node: _SoundNode {
        switch sourceKind {
        case .sample(let name): return .sample(name)
        case .fileSample(let fileURL, let rootPitch):
            return .fileSample(fileURL: fileURL, rootPitch: rootPitch)
        case .sampleBank(let bank): return .sampleBank(bank)
        case .synthesizer:
            fatalError("Sample cannot contain a synthesizer source")
        }
    }
}
