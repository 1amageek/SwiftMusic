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

SpectrumAnalyzer owns a reusable Accelerate complex DFT setup and buffers on MainActor. At most 30 Hz, it analyzes the 2048 stereo frames preceding the adopted transport cursor, wrapping at loop boundaries. A Hann window and channel-averaged power prevent opposite-phase stereo cancellation; 96 logarithmic bands cover 20 Hz to 20 kHz, normalized to peak amplitude dBFS with a -90 dB floor. Paused or absent playback displays silence. Analysis is outside the audio callback and reports setup failure. This visualizes prepared post-mix PCM at the transport cursor, not microphone or hardware loopback. Sine frequency/amplitude, stereo opposition, silence and loop-boundary tests own correctness.
