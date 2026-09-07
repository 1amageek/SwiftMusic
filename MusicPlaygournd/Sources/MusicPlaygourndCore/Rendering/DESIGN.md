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
PreparedLoop.rows retains each compiled source and its optional compiler pattern anchor even when no events fire. `LoopRow.resultLine` is an optional positive Session.swift line populated by SourceEvaluator from compiler AST provenance; optionality preserves standalone renderer construction, while successfully evaluated anchored rows must have it before submission. Each row carries at most 512 peak bins derived from the actual pre-mix source PCM; labels explicitly identify the pre-mix signal, which does not imply audible gain or mute state. LoopRow source IDs link to LoopEvent timing, and each event preserves its optional compiled pattern-step index so the adopted transport can identify the exact active token. Validation rejects invalid anchors or result lines, duplicate row IDs, invalid event step indices, nonfinite or negative peaks and excess rows/bins.

SpectrumAnalyzer owns a reusable Accelerate complex DFT setup and buffers on MainActor. At most 30 Hz, it analyzes the playback owner's latest bounded 2,048-frame post-FX stereo snapshot using that snapshot's actual sample rate. A Hann window and channel-averaged power prevent opposite-phase stereo cancellation; 96 logarithmic bands cover 20 Hz to 20 kHz, normalized to peak amplitude dBFS with a -90 dB floor. Paused or absent playback displays silence. Analysis is outside the audio callback and reports setup failure. This visualizes the owned master effects output before hardware volume, not prepared PCM, microphone, or hardware loopback. Frequency/amplitude, stereo opposition, silence, sample-rate, and snapshot-bound tests own correctness.

### Patterned per-event gain
SwiftMusic supplies finite, nonnegative CompiledSoundEvent.gain selected at event onset. The renderer multiplies each voice by this gain before mixing and existing ordered scalar gain nodes. Zero renders silence without inventing or removing rhythmic events. The same value is retained in LoopEvent; inactive zero-gain tokens do not glow. Float amplitude overflow produces an explicit invalid-event diagnostic. PCM tests compare onset-aligned nested gain values, silent spans, relative amplitudes and unchanged scalar gain behavior.

### Patterned per-event pan

SwiftMusic supplies optional `CompiledSoundEvent.pan` in `-1...1`, sampled at the exact event onset. Nil bypasses per-event panning and preserves existing centered PCM exactly; every resolved value, including zero, uses the existing scalar pan node's equal-power cosine/sine law before source mixing. LoopRenderer copies the optional value to `LoopEvent.pan`; decoding legacy LoopEvent data without this field yields nil. Final finite-PCM validation and output clamping remain unchanged, and scalar pan render nodes keep their graph order and behavior. Tests compare left/right PCM for endpoints and explicit center, verify nil default and legacy decode compatibility, reject nonfinite/out-of-range decoded values, and retain scalar-pan evidence.

### Native source performance

LoopRenderer consumes SwiftMusic's immutable envelope, per-voice filter, sample-reference, traversal, voice-policy, choke, and event-override metadata. It owns DSP, file decoding through an injected `SampleLoading` protocol, selected-asset caching for one render, deterministic voice allocation, and conversion into PreparedLoop PCM. SwiftMusic remains the authority for musical time and metadata; Playback consumes the finished loop and does not reinterpret source policy.

For an envelope, the audible horizon includes release after the selected gate/event anchor. The renderer computes the maximum finite release end at the requested BPM before whole-bar padding and applies the existing 32-beat/16-second limits to that complete horizon; it fails instead of clipping an otherwise valid release. Nil envelope/filter/voice policy preserves prior PCM behavior. Source filtering is stable per-voice processing before event gain/pan and source mixing; existing post-mix AudioEffect nodes remain unsupported until their owning effects sprint.

File and bank sources decode only explicitly selected local assets. The loader validates format, channels, rate, frame/sample finiteness, duration and distinct-asset bounds before rendering; region, reverse and non-pitch-preserving rate operate on the decoded asset without changing event time. Decode, lookup, resample or bound failure is a typed LoopRenderingError and never invokes procedural percussion fallback. Voice release, stealing and choke remain bounded by compiled events and frame count, use deterministic ties, and apply a bounded anti-click ramp.

Swift Testing fixtures compare actual PCM and frequency/filter/envelope measurements, decode temporary mono/stereo files through the production loader, exercise every failure and cache bound, and prove voice stealing/choke order. Integration submits a rendered loop to the native engine and observes nonzero output while evaluation failure retains the previous revision.
