/// An ordered, immutable collection of explicitly named sample assets.
public struct SampleBank: Sendable, Equatable, Hashable {
    public let assets: [SampleAsset]

    public init(_ assets: [SampleAsset]) throws {
        guard !assets.isEmpty else {
            throw SampleDescriptorError.emptyBank
        }
        var keys = Set<String>()
        keys.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            try SampleAsset.validateKey(asset.key, index: index)
            guard keys.insert(asset.key).inserted else {
                throw SampleDescriptorError.duplicateKey(asset.key)
            }
        }
        self.assets = assets
    }

    internal func contains(_ key: String) -> Bool {
        assets.contains { $0.key == key }
    }

    internal var firstKey: String {
        assets[0].key
    }
}
