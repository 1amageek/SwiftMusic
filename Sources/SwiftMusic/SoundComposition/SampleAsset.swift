import Foundation

/// One explicitly named decoded asset in a sample bank.
public struct SampleAsset: Sendable, Equatable, Hashable {
    public let key: String
    public let fileURL: URL
    public let rootPitch: Pitch

    public init(
        key: String,
        fileURL: URL,
        rootPitch: Pitch = .middleC
    ) throws {
        guard SampleAsset.isAbsoluteFileURL(fileURL) else {
            throw SampleDescriptorError.invalidFileURL
        }
        try SampleAsset.validateKey(key, index: 0)
        self.key = key
        self.fileURL = fileURL
        self.rootPitch = rootPitch
    }

    internal static func isAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && !url.path.isEmpty && url.path.hasPrefix("/")
    }

    internal static func validateKey(_ key: String, index: Int) throws {
        do {
            var parser = try _MiniPatternParser(key)
            let program = try parser.parse()
            guard program.naturalPeriod == 1,
                  program.leaves.count == 1,
                  let leaf = program.leaves.first,
                  leaf.token == key,
                  leaf.token != "~" else {
                throw SampleDescriptorError.invalidKey(index: index)
            }
        } catch let error as SampleDescriptorError {
            throw error
        } catch {
            throw SampleDescriptorError.invalidKey(index: index)
        }
    }
}
