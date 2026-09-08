import Foundation
import SwiftMusic

/// Retains one compiled graph and its decoded sample preparation for bounded rerenders.
public struct LoopRenderSession: Sendable {
    public let revision: UInt64
    public let catalog: LiveControlCatalog
    public let baseline: PreparedLoop

    private let sound: CompiledSound
    private let bpm: Double
    private let beatsPerBar: Int
    private let renderer: LoopRenderer
    private let preparedSamples: SamplePreparation

    public init(
        sound: CompiledSound,
        bpm: Double,
        beatsPerBar: Int,
        revision: UInt64 = 0,
        sampleLoader: any SampleLoading = AVAudioFileSampleLoader()
    ) throws {
        let renderer = LoopRenderer(sampleLoader: sampleLoader)
        try renderer.validateBasicInputs(sound, bpm: bpm, beatsPerBar: beatsPerBar)
        let preparedSamples = try SamplePreparation(sound: sound, loader: sampleLoader, secondsPerBeat: 60 / bpm)
        let catalog = try LiveControlCatalog(sound: sound, revision: revision)
        let baseline = try renderer.renderPrepared(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples
        )
        self.revision = revision
        self.catalog = catalog
        self.baseline = baseline
        self.sound = sound
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.renderer = renderer
        self.preparedSamples = preparedSamples
    }

    /// Renders the complete active override set against the retained graph.
    /// An empty set is the release operation and returns the immutable baseline.
    public func render(overrides: [LiveControlOverride] = []) throws -> PreparedLoop {
        try Task.checkCancellation()
        guard !overrides.isEmpty else { return baseline }
        let overlay = try RenderControlOverlay.make(
            overrides: overrides,
            catalog: catalog,
            revision: revision
        )
        for event in sound.events {
            guard let offset = overlay.sourcePitch[event.sourceID] else { continue }
            let midi = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
            let depth = sound.sources[event.sourceID].pitchEnvelope?.depth.value ?? 0
            for base in [midi, event.portamentoStartMIDINote ?? midi] {
                guard (0...127).contains(base + offset), (0...127).contains(base + offset + depth) else {
                    throw LoopRenderingError.invalidSound("live pitch override exceeds MIDI range")
                }
            }
        }
        let rendered = try renderer.renderPrepared(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            overlay: overlay
        )
        try Task.checkCancellation()
        try validateShape(rendered)
        return rendered
    }

    private func validateShape(_ rendered: PreparedLoop) throws {
        guard rendered.sampleRate == baseline.sampleRate,
              rendered.bpm == baseline.bpm,
              rendered.beatsPerBar == baseline.beatsPerBar,
              rendered.beatCount == baseline.beatCount,
              rendered.samples.count == baseline.samples.count,
              rendered.events.count == baseline.events.count,
              rendered.rows.count == baseline.rows.count else {
            throw LoopRenderingError.invalidSound("live override changed the prepared loop shape")
        }
        for (before, after) in zip(baseline.events, rendered.events) {
            guard before.sourceID == after.sourceID,
                  before.label == after.label,
                  before.startBeat == after.startBeat,
                  before.velocity == after.velocity,
                  before.patternStepIndex == after.patternStepIndex else {
                throw LoopRenderingError.invalidSound("live override changed event provenance")
            }
        }
        for (before, after) in zip(baseline.rows, rendered.rows) {
            guard before.sourceID == after.sourceID,
                  before.label == after.label,
                  before.anchor == after.anchor,
                  before.resultLine == after.resultLine,
                  before.patternText == after.patternText else {
                throw LoopRenderingError.invalidSound("live override changed row provenance")
            }
        }
    }
}
