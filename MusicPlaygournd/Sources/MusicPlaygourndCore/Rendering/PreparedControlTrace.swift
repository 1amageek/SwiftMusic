import Foundation

/// One voice or one shared graph clock, including unwrapped boundary continuation.
public struct PreparedControlTrace: Codable, Sendable, Equatable {
    public struct Channel: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case selectedValue, amplitudeEnvelope, pitchEnvelope, filterEnvelope }
        public struct Point: Codable, Sendable, Equatable {
            public let beat: Double
            public let value: Double
            public init(beat: Double, value: Double) { self.beat = beat; self.value = value }
        }
        public let kind: Kind
        public let points: [Point]
        public init(kind: Kind, points: [Point]) { self.kind = kind; self.points = points }
    }
    public let eventIndex: Int?
    public let sourceID: Int?
    public let startBeat: Double
    public let durationBeats: Double
    public let wrapsLoopBoundary: Bool
    public let channels: [Channel]

    public init(eventIndex: Int?, sourceID: Int?, startBeat: Double, durationBeats: Double,
                wrapsLoopBoundary: Bool, channels: [Channel]) {
        self.eventIndex = eventIndex
        self.sourceID = sourceID
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.wrapsLoopBoundary = wrapsLoopBoundary
        self.channels = channels
    }
}
