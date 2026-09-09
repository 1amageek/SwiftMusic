internal enum _SoundModifier: Sendable {
    case parameterDeclaration(@Sendable () throws -> _SoundModifier, SoundSourceAnchor)
    case swing(Swing)
    case euclidean(EuclideanRhythm)
    case ratchet(Int)
    case probability(Probability)
    case humanize(Humanization)
    case periodically(PeriodicRhythmTransform)
    case oneShot
    case rhythm(RhythmPattern, MusicalTime, SoundSourceAnchor)
    case offset(MusicalTime)
    case repeated(Int)
    case fast(UInt64)
    case slow(UInt64)
    case notes([Pitch], SoundSourceAnchor)
    case notePattern(NotePattern, MusicalTime, SoundSourceAnchor)
    case transpose(Int)
    case pitchPattern(PitchPattern, MusicalTime, SoundSourceAnchor)
    case scaleNotes([ScaleDegree], Key, SoundSourceAnchor)
    case voicing(Voicing)
    case inversion(Int)
    case arpeggio(Arpeggio)
    case legato(Legato)
    case portamento(Portamento)
    case chord(Chord)
    case dynamic(Dynamic)
    case velocity(Int)
    case gate(Double)
    case staccato
    case tuning(Tuning)
    case envelope(Envelope)
    case pitchEnvelope(EnvelopeModulation)
    case filterEnvelope(EnvelopeModulation)
    case fixedFilter(FilterKind, Frequency, Double, FilterSlope)
    case cutoffPattern(FilterKind, CutoffPattern, MusicalTime, Double, FilterSlope, SoundSourceAnchor)
    case envelopePattern(EnvelopePattern, MusicalTime, SoundSourceAnchor)
    case sampleSelection(SampleSelectionPattern, MusicalTime, SoundSourceAnchor)
    case sampleSlice(SampleSlice)
    case chopped(Int)
    case granular(GranularPlayback)
    case sampleStretch(MusicalTime)
    case sampleRegion(SampleRegion)
    case sampleReversed
    case samplePlaybackRate(Double)
    case unison(Unison)
    case voicePolicy(VoicePolicy)
    case chokeGroup(String)
    case effect(AudioEffect)
    case tremolo(ModulationRate, Double, LFOWaveform)
    case vibrato(ModulationRate, Semitones, LFOWaveform)
    case position(SpatialPosition)
    case gain(Double)
    case gainPattern(GainPattern, MusicalTime, SoundSourceAnchor)
    case gainAutomation(GainAutomation)
    case pan(Double)
    case panPattern(PanPattern, MusicalTime, SoundSourceAnchor)
    case panAutomation(PanAutomation)
    case duck(String, Decibels, Duration, Duration)
    case pitchAutomation(PitchAutomation)
    case cutoffAutomation(FilterKind, CutoffAutomation, Double, FilterSlope)
    case muted
    case send(String, Double)
    case output(String)

    var sourceAnchor: SoundSourceAnchor? {
        switch self {
        case .parameterDeclaration(_, let anchor), .rhythm(_, _, let anchor), .notes(_, let anchor),
             .notePattern(_, _, let anchor), .scaleNotes(_, _, let anchor),
             .gainPattern(_, _, let anchor), .panPattern(_, _, let anchor),
             .pitchPattern(_, _, let anchor),
             .cutoffPattern(_, _, _, _, _, let anchor),
             .envelopePattern(_, _, let anchor),
             .sampleSelection(_, _, let anchor):
            anchor
        default:
            nil
        }
    }

    var sourcePatternText: String? {
        switch self {
        case .rhythm(let pattern, _, _): pattern.rawValue
        case .notePattern(let pattern, _, _): pattern.rawValue
        case .pitchPattern(let pattern, _, _): pattern.rawValue
        case .cutoffPattern(_, let pattern, _, _, _, _): pattern.rawValue
        case .envelopePattern(let pattern, _, _): pattern.rawValue
        case .sampleSelection(let pattern, _, _): pattern.rawValue
        case .gainPattern(let pattern, _, _): pattern.rawValue
        case .panPattern(let pattern, _, _): pattern.rawValue
        default: nil
        }
    }
}
