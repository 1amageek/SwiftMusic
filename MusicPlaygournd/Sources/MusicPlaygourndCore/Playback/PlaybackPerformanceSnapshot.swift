import Foundation

/// Measures this source callback, not total Audio Unit or system CPU usage.
public struct PlaybackPerformanceSnapshot: Sendable, Equatable {
    public let callbackLoad: Double?
    public let dropoutCount: UInt64
    public let peak: Float?
    public let clipped: Bool

    public init(callbackLoad: Double?, dropoutCount: UInt64, peak: Float?, clipped: Bool) {
        self.callbackLoad = callbackLoad
        self.dropoutCount = dropoutCount
        self.peak = peak
        self.clipped = clipped
    }
}
