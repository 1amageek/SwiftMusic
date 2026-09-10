/// Failures while constructing an immutable file or sample-bank descriptor.
public enum SampleDescriptorError: Error, Equatable, Sendable {
    case invalidFileURL
    case emptyBank
    case invalidKey(index: Int)
    case duplicateKey(String)
    case invalidPlaybackRate(Double)
    case invalidSlice(index: Int, count: Int)
    case invalidChopCount(Int)
    case invalidGranularDuration
    case invalidGranularOverlap(Double)
    case invalidGranularJitter(Double)
    case invalidStretchDuration(MusicalTime)
}
