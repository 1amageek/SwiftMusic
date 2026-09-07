import Foundation

public extension Sound {
    func tuning(_ value: Tuning) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .tuning(value))
    }

    func envelope(_ value: Envelope) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .envelope(value))
    }

    func envelope(_ pattern: EnvelopePattern, cycle: MusicalTime = .whole) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .envelopePattern(pattern, cycle))
    }

    func pitchEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .pitchEnvelope(EnvelopeModulation(envelope: envelope, depth: depth))
        )
    }

    func filterEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .filterEnvelope(EnvelopeModulation(envelope: envelope, depth: depth))
        )
    }

    func lowPass(
        _ cutoff: Frequency,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .fixedFilter(.lowPass, cutoff, resonanceQ, slope))
    }

    func highPass(
        _ cutoff: Frequency,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .fixedFilter(.highPass, cutoff, resonanceQ, slope))
    }

    func bandPass(
        _ cutoff: Frequency,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .fixedFilter(.bandPass, cutoff, resonanceQ, slope))
    }

    func lowPass(
        _ pattern: CutoffPattern,
        cycle: MusicalTime = .whole,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .cutoffPattern(.lowPass, pattern, cycle, resonanceQ, slope))
    }

    func lowPass(
        _ automation: CutoffAutomation,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .cutoffAutomation(.lowPass, automation, resonanceQ, slope))
    }

    func highPass(
        _ pattern: CutoffPattern,
        cycle: MusicalTime = .whole,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .cutoffPattern(.highPass, pattern, cycle, resonanceQ, slope)
        )
    }

    func highPass(
        _ automation: CutoffAutomation,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .cutoffAutomation(.highPass, automation, resonanceQ, slope))
    }

    func bandPass(
        _ pattern: CutoffPattern,
        cycle: MusicalTime = .whole,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(
            base: self,
            modifier: .cutoffPattern(.bandPass, pattern, cycle, resonanceQ, slope)
        )
    }

    func bandPass(
        _ automation: CutoffAutomation,
        resonanceQ: Double = 0.7071067811865476,
        slope: FilterSlope = .twelve
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .cutoffAutomation(.bandPass, automation, resonanceQ, slope))
    }

    func sampleRegion(_ value: SampleRegion) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .sampleRegion(value))
    }

    func sampleSelection(
        _ pattern: SampleSelectionPattern,
        cycle: MusicalTime = .whole
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .sampleSelection(pattern, cycle))
    }

    func sampleReversed() -> ModifiedSound {
        ModifiedSound(base: self, modifier: .sampleReversed)
    }

    func samplePlaybackRate(_ rate: Double) throws -> ModifiedSound {
        guard rate.isFinite, rate > 0 else {
            throw SampleDescriptorError.invalidPlaybackRate(rate)
        }
        return ModifiedSound(base: self, modifier: .samplePlaybackRate(rate))
    }

    func voicePolicy(_ policy: VoicePolicy) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .voicePolicy(policy))
    }

    func chokeGroup(_ name: String) throws -> ModifiedSound {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SoundParameterError.invalidValue("chokeGroup")
        }
        return ModifiedSound(base: self, modifier: .chokeGroup(normalized))
    }

    func unison(_ value: Unison) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .unison(value))
    }
}
