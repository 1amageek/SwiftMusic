# Rendering

## Purpose and Scope
Component. Parent: [Core](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
LoopRenderer owns offline PCM synthesis and graph processing. It consumes SwiftMusic CompiledSound and produces both PCM and visual events.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
CompiledSound + bpm + beatsPerBar -> validation -> sources -> ordered graph -> PreparedLoop
```

## Contracts and Invariants
API: LoopRenderer().render(_ sound: CompiledSound, bpm: Double, beatsPerBar: Int) throws -> PreparedLoop. BPM 40...240; quarter-note meter 2...7. Pad extent to whole bars. Duration <=16 seconds, extent <=32 beats, sources <=32, events <=1024, nodes <=256; fail before unbounded allocation. Synth sine/square/saw/triangle/noise, original built-in percussion kick/snare/closedHat, gain/pan/mute supported. Source settings, effects and routing not supported in this version fail with typed errors. No silent fallback. Sustain/release are bounded by event gate and loop; short edge fades prevent clicks; no preserved effect tail is claimed.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Tests compare audible PCM, silence, gain/pan, timing, invalid feature and bound failures. Document any actual signal/tail ceilings. Memory bounded per-node via frame/node work budget.

### Visual signal contract
PreparedLoop.rows retains each compiled source and its optional compiler anchor even when no events fire. Each row carries at most 512 peak bins derived from the actual pre-mix source PCM; labels explicitly identify the pre-mix signal, which does not imply audible gain or mute state. LoopRow source IDs link to LoopEvent timing, and each event preserves its optional compiled pattern-step index so the adopted transport can identify the exact active token. Validation rejects invalid anchors, duplicate row IDs, invalid event step indices, nonfinite or negative peaks and excess rows/bins.

SpectrumAnalyzer owns a reusable Accelerate complex DFT setup and buffers on MainActor. At most 30 Hz, it analyzes the playback owner's latest bounded 2,048-frame post-FX stereo snapshot using that snapshot's actual sample rate. A Hann window and channel-averaged power prevent opposite-phase stereo cancellation; 96 logarithmic bands cover 20 Hz to 20 kHz, normalized to peak amplitude dBFS with a -90 dB floor. Paused or absent playback displays silence. Analysis is outside the audio callback and reports setup failure. This visualizes the owned master effects output before hardware volume, not prepared PCM, microphone, or hardware loopback. Frequency/amplitude, stereo opposition, silence, sample-rate, and snapshot-bound tests own correctness.

### Patterned per-event gain
SwiftMusic supplies finite, nonnegative CompiledSoundEvent.gain selected at event onset. The renderer multiplies each voice by this gain before mixing and existing ordered scalar gain nodes. Zero renders silence without inventing or removing rhythmic events. The same value is retained in LoopEvent; inactive zero-gain tokens do not glow. Float amplitude overflow produces an explicit invalid-event diagnostic. PCM tests compare onset-aligned nested gain values, silent spans, relative amplitudes and unchanged scalar gain behavior.
