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
    private let preparedOscillators: [Int: OscillatorPreparation]

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
        let preparedOscillators = try OscillatorPreparation.prepare(sound)
        let catalog = try LiveControlCatalog(sound: sound, revision: revision)
        let baseline = try renderer.renderPrepared(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            preparedOscillators: preparedOscillators
        )
        self.revision = revision
        self.catalog = catalog
        self.baseline = baseline
        self.sound = sound
        self.bpm = bpm
        self.beatsPerBar = beatsPerBar
        self.renderer = renderer
        self.preparedSamples = preparedSamples
        self.preparedOscillators = preparedOscillators
    }

    /// Renders the complete active override set against the retained graph.
    /// An empty set is the release operation and returns the immutable baseline.
    public func render(overrides: [LiveControlOverride] = []) throws -> PreparedLoop {
        try Task.checkCancellation()
        let overlay = try makeOverlay(overrides)
        guard !overrides.isEmpty else { return baseline }
        let rendered = try renderer.renderPrepared(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            preparedOscillators: preparedOscillators,
            overlay: overlay
        )
        try Task.checkCancellation()
        try validateShape(rendered)
        return rendered
    }

    /// Captures every compiled Track boundary in stable declaration order.
    public func renderStems(overrides: [LiveControlOverride] = []) throws -> [PreparedStem] {
        try Task.checkCancellation()
        let overlay = try makeOverlay(overrides)
        let result = try renderer.renderPreparedAndStems(
            sound,
            bpm: bpm,
            beatsPerBar: beatsPerBar,
            preparedSamples: preparedSamples,
            preparedOscillators: preparedOscillators,
            overlay: overlay
        )
        try Task.checkCancellation()
        try validateShape(result.loop)
        return result.stems
    }

    /// Samples the selected control without rendering, adopting or mutating audio.
    public func visualization(for address: LiveControlAddress,
                              overrides: [LiveControlOverride] = []) throws -> PreparedControlVisualization {
        guard address.revision == revision else {
            throw LiveControlError.staleRevision(expected: revision, actual: address.revision)
        }
        guard let descriptor = catalog.descriptor(for: address) else { throw LiveControlError.unknownAddress(address) }
        let overlay = try makeOverlay(overrides)
        return try ControlVisualizationRenderer.render(sound: sound, loop: baseline, samples: preparedSamples,
            descriptor: descriptor, overlay: overlay)
    }

    private func makeOverlay(_ overrides: [LiveControlOverride]) throws -> RenderControlOverlay? {
        guard !overrides.isEmpty else { return nil }
        let overlay = try RenderControlOverlay.make(
            overrides: overrides,
            catalog: catalog,
            revision: revision
        )
        for event in sound.events {
            guard let offset = overlay.sourcePitch[event.sourceID] else { continue }
            let midi = Double(event.pitch?.midiNote ?? 60) + event.pitchOffsetSemitones
            let source = sound.sources[event.sourceID]
            let depth = source.pitchEnvelope?.depth.value ?? 0
            let detune = (source.unison?.voices ?? 1) > 1 ? (source.unison?.detuneCents ?? 0) / 100 : 0
            for base in [midi, event.portamentoStartMIDINote ?? midi] {
                guard (0...127).contains(base + offset - detune), (0...127).contains(base + offset + detune),
                      (0...127).contains(base + offset + depth - detune),
                      (0...127).contains(base + offset + depth + detune) else {
                    throw LoopRenderingError.invalidSound("live pitch override exceeds MIDI range")
                }
            }
        }
        return overlay
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
