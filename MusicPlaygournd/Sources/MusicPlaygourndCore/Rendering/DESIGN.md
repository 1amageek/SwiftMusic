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

PreparedLoop validation uses the same lexical boundary contract as PlayingLiteral: ASCII angle/square brackets and whitespace are structural delimiters, while a leaf's `*count` suffix and comma-separated note members remain one token. It validates each event index against this compiler-compatible token count and never counts punctuation as a phantom sounding step. CyclePatternRenderingTests own compiler-to-LoopEvent indices, complete multi-cycle PCM and out-of-bound failure; VisualFeedbackTests own the matching source ranges.

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

### Finite and live-loop rendering

LoopRenderer does not interpret recurrence or copy compiled events. MusicPlaygournd evaluation requests `SoundCompiler.compile(_:liveLoop:)` with the current quarter-note bar and a maximum beat horizon derived from the existing 32-beat and 16-second preparation limits, then passes the fully expanded CompiledSound to the existing renderer API. Other clients using finite `compile(_:)` and the same renderer retain their prior behavior.

The live CompiledSound extent is already a checked whole-bar common window, and every event already contains its final onset-sampled gain, pan, pitch and provenance. LoopRenderer validates that extent under its existing beat/duration/event limits and renders it once. AudioLoopEngine repeats the finished common window, so independent track and numeric-pattern phases survive wrap without renderer-owned musical semantics.

For `.finite`, LoopRenderer retains its existing end-of-window clipping and edge-fade behavior. For `.seamlessLoop`, an event whose full gated duration crosses `beatCount` is folded into two segments in the same PCM buffer: onset through the window end and beat zero through the true release. Oscillator/sample elapsed time and envelope phase continue across the split; the split adds no attack, release or edge fade. The existing attack fade occurs only at the true onset and the release fade only at the true end. Per-source peak PCM uses the same folded signal. A crossing duration greater than the window or invalid folded frame arithmetic is a typed rendering failure, never a clipped success.

`LoopEvent.durationBeats` retains the full audible duration and `wrapsLoopBoundary` records that its active interval is circular; legacy decoding defaults the flag to false. PreparedLoop validation requires `0 <= startBeat < beatCount`, positive finite duration, and either a nonwrapping end within the window or a wrapping end beyond it with duration no greater than `beatCount`. Rhythm, timeline and inline views draw the two visible segments of a wrapped event. Transport/token activity uses the same circular interval (`beat >= start` or `beat < end - beatCount`) and one `sourceID`/`patternStepIndex`, so the literal remains active through beat zero without a phantom second token.

Tests compare finite and live compiler results rendered through the same LoopRenderer; cover independent 3/4 and 4/4 cycles, nested LCM, gain alternation across later cycles, fractional-rate pan periods, bare/oneShot/finite-repeat behavior, exact modifier values and PCM, all-rest windows and explicit compiler/renderer bounds; and retain the last adopted loop after live compilation failure. A boundary fixture with onset 3, duration 4 and window 4 proves continuous PCM/envelope phase across frames 3...0, one attack and one release, full LoopEvent duration, split visualization and uninterrupted token activity. A native playback test observes this event and independent phase through a completed common-window wrap without retrigger or phase reset.
