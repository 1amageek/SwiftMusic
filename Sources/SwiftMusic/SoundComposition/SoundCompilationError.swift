public enum SoundCompilationError: Error, Equatable, Sendable {
    case invalidRhythm(RhythmPatternError)
    case invalidNotes(NotePatternError)
    case invalidGainPattern(GainPatternError)
    case invalidPanPattern(PanPatternError)
    case invalidPitchPattern(PitchPatternError)
    case invalidCutoffPattern(CutoffPatternError)
    case invalidEnvelopePattern(EnvelopePatternError)
    case invalidSampleSelection(SampleSelectionPatternError)
    case unexpectedFailure(String)
    case invalidParameter(String)
    case unsupportedSourceSetting(String)
    case unknownSampleKey(key: String, utf8Offset: Int?)
    case missingPitch
    case pitchOutOfRange
    case timeOverflow
    case maximumDepthExceeded(limit: Int)
    case maximumEventsExceeded(limit: Int)
    case maximumTracksExceeded(limit: Int)
    case maximumSourcesExceeded(limit: Int)
    case maximumRenderNodesExceeded(limit: Int)
    case invalidBusRouting(BusRoutingError)
    case liveWindowExceeded(maximum: MusicalTime)
    case liveEventDurationExceeded(index: Int)
}
