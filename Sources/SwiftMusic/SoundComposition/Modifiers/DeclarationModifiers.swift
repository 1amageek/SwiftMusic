import Foundation

public extension Sound {
    /// Defers parameter validation until sound compilation.
    func envelope(
        attack: Duration, decay: Duration, sustainLevel: Double, release: Duration,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd,
        fileID: String = #fileID, line: Int = #line, column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .parameterDeclaration({
            .envelope(try Envelope(attack: attack, decay: decay, sustainLevel: sustainLevel, release: release,
                attackCurve: attackCurve, decayCurve: decayCurve, releaseCurve: releaseCurve,
                releaseAnchor: releaseAnchor))
        }, SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }

    /// Defers parameter validation until sound compilation.
    func filterEnvelope(
        attack: Duration, decay: Duration, sustainLevel: Double, release: Duration,
        depth: Double,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd,
        fileID: String = #fileID, line: Int = #line, column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .parameterDeclaration({
            .filterEnvelope(EnvelopeModulation(envelope: try Envelope(attack: attack, decay: decay, sustainLevel: sustainLevel, release: release,
                attackCurve: attackCurve, decayCurve: decayCurve, releaseCurve: releaseCurve,
                releaseAnchor: releaseAnchor), depth: try Semitones(value: depth)))
        }, SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }

    /// Defers parameter validation until sound compilation.
    func pitchEnvelope(
        attack: Duration, decay: Duration, sustainLevel: Double, release: Duration,
        depth: Double,
        attackCurve: EnvelopeCurve = .linear,
        decayCurve: EnvelopeCurve = .linear,
        releaseCurve: EnvelopeCurve = .linear,
        releaseAnchor: EnvelopeReleaseAnchor = .gateEnd,
        fileID: String = #fileID, line: Int = #line, column: Int = #column
    ) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .parameterDeclaration({
            .pitchEnvelope(EnvelopeModulation(envelope: try Envelope(attack: attack, decay: decay, sustainLevel: sustainLevel, release: release,
                attackCurve: attackCurve, decayCurve: decayCurve, releaseCurve: releaseCurve,
                releaseAnchor: releaseAnchor), depth: try Semitones(value: depth)))
        }, SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }

    /// Defers unison voice-count and detuning validation until compilation.
    func unison(voices: Int, detuneCents: Double,
                fileID: String = #fileID, line: Int = #line, column: Int = #column) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .parameterDeclaration({
            .unison(try Unison(voices: voices, detuneCents: detuneCents))
        }, SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }

    /// Declares duck depth in decibels and validates it during compilation.
    func duck(targetBus: String, depth: Double, attack: Duration, recovery: Duration,
              fileID: String = #fileID, line: Int = #line, column: Int = #column) -> ModifiedSound {
        ModifiedSound(base: self, modifier: .parameterDeclaration({
            .duck(targetBus, try Decibels(value: depth), attack, recovery)
        }, SoundSourceAnchor(fileID: fileID, line: line, column: column)))
    }
}
