/// A bounded, zero-based subdivision of a decoded sample region.
public struct SampleSlice: Sendable, Equatable, Hashable {
    public let index: Int
    public let count: Int

    public init(index: Int, count: Int) throws {
        guard (1...1_024).contains(count), (0..<count).contains(index) else {
            throw SampleDescriptorError.invalidSlice(index: index, count: count)
        }
        self.index = index
        self.count = count
    }
}
