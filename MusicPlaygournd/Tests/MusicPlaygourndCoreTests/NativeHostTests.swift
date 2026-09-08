import Testing

/// Shares one serialization boundary across native audio, AppKit, and timed child-process tests.
@Suite(.serialized)
struct NativeHostTests {}
