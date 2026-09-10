# Automation

## Purpose and Scope

Time-varying parameter curves, envelopes and oscillation descriptors. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`AutomationCurve`, `AutomationError`, `AutomationInterpolation`, `AutomationPoint`, `AutomationSignal`, `CutoffAutomation`, `Envelope`, `EnvelopeCurve`, `EnvelopeModulation`, `EnvelopeReleaseAnchor`, `GainAutomation`, `LFO`, `LFOWaveform`, `ModulationRate`, `PanAutomation`, `PitchAutomation`, `StepAutomation`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../SoundComposition/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [MusicalValues](../MusicalValues/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Compilation](../Compilation/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [RenderPlan](../RenderPlan/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [Performance](../Performance/DESIGN.md); shared SwiftMusic types retain their existing access levels.

## Architecture

```text
Sound declarations + values + patterns + automation
    -> Compilation -> RenderPlan -> host
Performance -> declaration evaluation
```

## Contracts and Invariants

Source declarations, access levels, state isolation, error propagation and compiler ordering are unchanged by this layout. Public consumers continue to import SwiftMusic. Tests remain in one SwiftMusicTests target; production directories do not introduce separate representations or adapters.

## Verification and Change Impact

Verify every relocated Swift file against its original SHA-256 digest, run the SwiftMusic behavioral suite, and check documentation links and SwiftPM source discovery. Changes to these types require checking their compiler callers and the public tests; folder placement alone does not establish runtime correctness.

## Continuous Automation

P05.1 adds one shared signal vocabulary because LFO, steps and curves have identical normalized clock semantics, while application remains domain-specific. `AutomationSignal` is `lfo(LFO)`, `steps(StepAutomation)` or `curve(AutomationCurve)`. `LFOWaveform` is `sine`, `triangle`, `sawUp`, `sawDown` or `square`; `ModulationRate` is `hertz(Frequency)` or `synchronized(period: MusicalTime)`. `LFO.init(waveform:rate:phase:)` throws unless phase is finite in `0..<1` and the rate/period is positive. Every signal evaluates to finite `0...1`: sine is `(sin(2πp)+1)/2`, sawUp is `p`, sawDown is `1-p`, square is zero before half phase and one afterward, and triangle linearly visits zero, one and zero over a cycle.

`StepAutomation.init(values:cycle:)` throws unless it has 1...1,024 finite values in `0...1` and a positive cycle; values divide the cycle equally and hold until the next step. `AutomationPoint` has `position: MusicalTime`, `value: Double`, and `interpolationToNext: AutomationInterpolation`, where interpolation is `hold`, `linear` or `smoothstep`. `AutomationCurve.init(points:cycle:)` requires 1...1,024 points, a positive cycle, a first point at zero, strictly increasing positions below the cycle and normalized finite values. The final segment wraps to the first point at the cycle boundary using the last point's interpolation, so the curve has one defined cyclic value at every phase. `smoothstep` uses `t*t*(3-2*t)`. These are typed descriptors, not mini-notation or a public generic parameter-pattern facade.

Application types retain target validation and units: `GainAutomation.init(_:from:to:)` accepts finite nonnegative endpoints; `PanAutomation` accepts finite endpoints in `-1...1`; `PitchAutomation` accepts `Semitones`; and `CutoffAutomation` accepts `Frequency`. Endpoints may descend, and mapping is `from + normalized * (to - from)`. Sound overloads are `gain(_ automation: GainAutomation)`, `pan(_ automation: PanAutomation)`, `transpose(_ automation: PitchAutomation)`, and `lowPass/highPass/bandPass(_ automation: CutoffAutomation, resonanceQ:slope:)`. Existing scalar and domain-pattern overloads remain source-compatible. Gain/pan automation becomes dependency-ordered `CompiledRenderNode.gainAutomation(input:automation:)` / `panAutomation(input:automation:)`, preserving its declaration position. `CompiledSource.pitchAutomation: PitchAutomation?` and `cutoffAutomation: CutoffAutomation?` carry source automation to clients. Pitch automation is additive to the event's compiled pitch and onset-sampled pitch offset; the last continuous pitch automation declared for a source wins. A static, patterned or automated cutoff is one source-filter setting, so the outermost such declaration wins. Every reachable pitch endpoint must remain MIDI 0...127; cutoff endpoints must remain below the renderer Nyquist value. Unpitched procedural samples and white noise retain their explicit pitch-capability failures.

Onset patterns remain sampled by `SoundCompiler` and are never relabeled continuous. Continuous descriptors are retained unsampled in compiled sources/render nodes, and LoopRenderer evaluates them for every output frame using transport beat or elapsed seconds. A synchronized period contributes to live-loop common-period analysis and must divide the bounded compiled window by exact reduced `MusicalTime` rational remainder; it is never admitted or rejected through a Double quotient. Sound event-time modifiers such as `.fast` and `.slow` transform event recurrence only; they do not transform a retained continuous signal clock, regardless of whether the automation modifier appears inside or outside them. After event-program transformation and outermost source-setting replacement are complete, the compiler scans the final retained source automations and gain/pan automation nodes and combines each synchronized period with the transformed event period to choose the bounded common live window. Only an explicit rate/period in the automation descriptor changes its clock. An Hz LFO is BPM-independent; seamless rendering requires `frequency * physicalWindowSeconds`, where `physicalWindowSeconds` is the renderer's integer `frameCount / sampleRate`, to be a finite integral cycle count under the declared Double values. Otherwise rendering fails rather than resetting phase at the seam. Finite rendering accepts the same Hz signal through its owned horizon. Automation descriptor/point counts participate in existing compiler node/depth and 1,024-element bounds, with checked timing arithmetic before allocation. P05.1 adds no editor control identity or parameter provenance.

Code declaration order remains authoritative. Event gain/pan patterns keep their existing pre-source onset values; continuous gain/pan nodes then process the subtree at their graph position. Pitch automation adds to the already compiled event pitch/offset, while cutoff replacement follows the outermost source modifier rule above. P05.1 renders these four source/subtree automations into immutable PreparedLoop PCM while retaining every signal, mapping and target on `CompiledSound` sources/render nodes; PCM is not the sole semantic record. Failed/stale evaluation preserves that adopted automation and PCM. P05.1 itself exposes no callable live-control placeholder. The Playback design solely owns later live precedence and the retained-graph rerender/native-control path, and P05.7 must prove that path before an address is advertised as live.

Swift Testing proves all constructors and exact waveform/step/curve boundary values; descending mappings; declaration order against existing onset gain/pan/pitch/cutoff patterns; compiler node/source storage and final-descriptor synchronized-period contribution independent of surrounding event fast/slow order; effective-pitch, Nyquist, nonfinite, element and arithmetic failures; sample-accurate measured gain, stereo pan, oscillator pitch and RBJ cutoff movement; finite Hz behavior; seamless synchronized/Hz continuity at a non-frame-aligned 137 BPM window, physical-frame integral-Hz acceptance and nonintegral-Hz rejection; unchanged nil-automation PCM/events/provenance; and one compiled automated loop through native playback.
