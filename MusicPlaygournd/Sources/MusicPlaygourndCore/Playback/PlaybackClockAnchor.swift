import AVFoundation

/// A source beat paired with the host instant at which it reaches the output.
public struct PlaybackClockAnchor: Sendable, Equatable {
    public let presentationHostTime: UInt64
    public let accumulatedBeatPosition: Double
    public let beatsPerMinute: Double
    public let loopBeatCount: Double
    public let revision: UInt64
    public let overrideGeneration: UInt64
    public let isPlaying: Bool

    public init(presentationHostTime: UInt64, accumulatedBeatPosition: Double,
                beatsPerMinute: Double, loopBeatCount: Double, revision: UInt64,
                overrideGeneration: UInt64, isPlaying: Bool) throws {
        guard presentationHostTime > 0, accumulatedBeatPosition.isFinite, accumulatedBeatPosition >= 0,
              beatsPerMinute.isFinite, beatsPerMinute > 0, loopBeatCount.isFinite, loopBeatCount > 0 else {
            throw PlaybackClockError.outOfRange
        }
        self.presentationHostTime = presentationHostTime
        self.accumulatedBeatPosition = accumulatedBeatPosition
        self.beatsPerMinute = beatsPerMinute
        self.loopBeatCount = loopBeatCount
        self.revision = revision
        self.overrideGeneration = overrideGeneration
        self.isPlaying = isPlaying
    }

    public func beat(atHostTime hostTime: UInt64) throws -> Double {
        guard isPlaying else { return accumulatedBeatPosition }
        let forward = hostTime >= presentationHostTime
        let ticks = forward ? hostTime - presentationHostTime : presentationHostTime - hostTime
        let seconds = AVAudioTime.seconds(forHostTime: ticks)
        guard seconds <= 1 else { throw PlaybackClockError.discontinuous }
        let beat = accumulatedBeatPosition + (forward ? seconds : -seconds) * beatsPerMinute / 60
        guard beat.isFinite, beat >= 0 else { throw PlaybackClockError.outOfRange }
        return beat
    }

    public func hostTime(atBeat beat: Double) throws -> UInt64 {
        guard isPlaying else { throw PlaybackClockError.unavailable }
        let seconds = (beat - accumulatedBeatPosition) / beatsPerMinute * 60
        guard beat.isFinite, beat >= 0, seconds.isFinite, abs(seconds) <= 1 else {
            throw PlaybackClockError.outOfRange
        }
        let ticks = try Self.hostTicks(forSeconds: abs(seconds))
        let (host, overflow) = seconds >= 0
            ? presentationHostTime.addingReportingOverflow(ticks)
            : presentationHostTime.subtractingReportingOverflow(ticks)
        guard !overflow else { throw PlaybackClockError.outOfRange }
        return host
    }

    internal static func hostTicks(forSeconds seconds: Double) throws -> UInt64 {
        // Convert relative intervals only; converting an absolute UInt64 through Double loses ticks.
        guard seconds.isFinite, seconds >= 0,
              seconds < AVAudioTime.seconds(forHostTime: UInt64.max) else {
            throw PlaybackClockError.outOfRange
        }
        return AVAudioTime.hostTime(forSeconds: seconds)
    }
}

public enum PlaybackClockError: Error, Sendable, Equatable, LocalizedError {
    case unavailable
    case discontinuous
    case outOfRange

    public var errorDescription: String? {
        switch self {
        case .unavailable: "The audio presentation clock is not available yet."
        case .discontinuous: "The audio presentation clock timestamp is discontinuous."
        case .outOfRange: "The requested audio clock time is outside its valid range."
        }
    }
}
