public struct LoopEvent: Codable, Sendable, Equatable {
    public let sourceID: Int
    public let label: String
    public let startBeat: Double
    public let durationBeats: Double
    public let midiNote: Int?
    public let midiProjection: MIDIEventProjection
    public let pan: Double?
    public let gain: Double
    public let velocity: Int
    public let patternStepIndex: Int?
    public let wrapsLoopBoundary: Bool

    public init(
        sourceID: Int,
        label: String,
        startBeat: Double,
        durationBeats: Double,
        midiNote: Int?,
        velocity: Int,
        patternStepIndex: Int? = nil,
        gain: Double = 1,
        pan: Double? = nil,
        wrapsLoopBoundary: Bool = false,
        midiProjection: MIDIEventProjection? = nil
    ) {
        self.sourceID = sourceID
        self.label = label
        self.startBeat = startBeat
        self.durationBeats = durationBeats
        self.midiNote = midiNote
        self.midiProjection = midiProjection ?? (midiNote == nil ? .none : .unsupported(.legacyMetadataMissing))
        self.pan = pan
        self.gain = gain
        self.velocity = velocity
        self.patternStepIndex = patternStepIndex
        self.wrapsLoopBoundary = wrapsLoopBoundary
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try values.decode(Int.self, forKey: .sourceID)
        label = try values.decode(String.self, forKey: .label)
        startBeat = try values.decode(Double.self, forKey: .startBeat)
        durationBeats = try values.decode(Double.self, forKey: .durationBeats)
        midiNote = try values.decodeIfPresent(Int.self, forKey: .midiNote)
        midiProjection = try values.decodeIfPresent(MIDIEventProjection.self, forKey: .midiProjection)
            ?? (midiNote == nil ? .none : .unsupported(.legacyMetadataMissing))
        pan = try values.decodeIfPresent(Double.self, forKey: .pan)
        gain = try values.decode(Double.self, forKey: .gain)
        velocity = try values.decode(Int.self, forKey: .velocity)
        patternStepIndex = try values.decodeIfPresent(Int.self, forKey: .patternStepIndex)
        wrapsLoopBoundary = try values.decodeIfPresent(Bool.self, forKey: .wrapsLoopBoundary) ?? false
    }

    /// Tests the full voice interval, including its continuation at the beginning of a loop.
    public func isActive(at beat: Double, in loopBeats: Double) -> Bool {
        guard beat.isFinite, beat >= 0, beat < loopBeats else { return false }
        var active = false
        forEachBeatRange(in: loopBeats) { range in
            if range.contains(beat) { active = true }
        }
        return active
    }

    /// Visits at most two display segments without allocating an intermediate array.
    public func forEachBeatRange(in loopBeats: Double, _ body: (Range<Double>) -> Void) {
        guard loopBeats.isFinite, loopBeats > 0, startBeat.isFinite,
              startBeat >= 0, startBeat < loopBeats,
              durationBeats.isFinite, durationBeats > 0 else { return }
        let end = startBeat + durationBeats
        guard end.isFinite else { return }
        body(startBeat..<min(end, loopBeats))
        if wrapsLoopBoundary, end > loopBeats, durationBeats <= loopBeats {
            body(0..<(end - loopBeats))
        }
    }
}
