import Testing

/// Shares one serialization boundary across native audio and AppKit tests.
@Suite(.serialized)
struct NativeHostTests {}
