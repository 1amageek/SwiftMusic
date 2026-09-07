# SoundComposition

## Purpose and Scope

SoundComposition owns the path from declarative `Sound` through six modifier categories to immutable beat events and render-plan descriptors. Its parent is the [SwiftMusic module](../DESIGN.md). It has no children.

| Category | Supported operations |
|---|---|
| Rhythm | `rhythm(_:cycle:)`, `offset(_:)`, `repeated(_:)`, `fast(_:)`, `slow(_:)` |
| Pitch and harmony | `notes(_:)`, `transpose(_:)`, `chord(_:)` |
| Expression | `dynamic(_:)`, `velocity(_:)`, `gate(_:)`, `staccato()`, pattern `gain(_:cycle:)` |
| Source settings | `tuning(_:)`, `envelope(_:)`, `sampleRegion(_:)`, `unison(_:)` |
| Audio effects | `effect(_:)` with EQ, filter, compressor, distortion, delay, reverb, chorus |
| Mix and routing | scalar `gain(_:)`, `pan(_:)`, `muted()`, `send(to:level:)`, `output(_:)` |

Swing, quantization, scales, voicing, arpeggiation, accent, legato, techniques, pitch envelopes, general automation, and mini-notation operators beyond recursive brackets are deferred without placeholder APIs.

## Responsibilities and Boundaries

The component owns protocols, builders, `Sample` and `Synthesizer`, modifiers, parameter values, exact-time operations, scoped compilation, deterministic IDs, track metadata, event transforms, source descriptors, render nodes, and bounds. It does not load samples, generate oscillator samples, execute effects, schedule a clock, or render audio.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../DESIGN.md`](../DESIGN.md) | parent | module export boundary | Exports this component as SwiftMusic | Keep one public model |
| [`../../../DESIGN.md`](../../../DESIGN.md) | package ancestor | scope and evidence boundary | Defines package outcome | A render descriptor is not audible DSP evidence |
| [`../../../Tests/SwiftMusicTests`](../../../Tests/SwiftMusicTests) | verification owner | public SwiftMusic API | Proves behavior | Observe values and graph order, not types alone |

## Architecture

```text
SoundBuilder parallel group
  |-- Sample / Synthesizer ---- source descriptor + initial event
  |-- Track ------------------- metadata only
  |-- event modifier ---------- scoped event transform
  |-- source setting ---------- scoped leaf-source update
  `-- effect / mix modifier --- post-mix node around subtree root
                                    |
                                    v
SoundCompiler -> subtree fragments -> CompiledSound
```

Each visit returns a subtree fragment of events, sources, tracks, dependency-ordered nodes, roots, and extent. A wrapper transforms only that fragment before sibling merge.

## Contracts and Invariants

### Declaration and sources

```swift
public protocol Music: Sendable {
    associatedtype Body: Sound
    @SoundBuilder var body: Body { get }
}

public protocol Sound: Sendable {
    associatedtype Body: Sound
    @SoundBuilder var body: Body { get }
}
```

`SoundBuilder` supports empty bodies, siblings, `if`, `if/else`, availability, and finite `for` loops. Siblings are parallel; declaration order only breaks equal-time ties. Package terminals are recognized before `body`; external bodies expand within the depth bound. `Never: Sound` is not visited.

Sources are `Sample(_ name: String)` and `Synthesizer(_ waveform: Waveform)`. Each initially emits one event at zero with quarter-note duration. Sample is unpitched; Synthesizer initially uses `Pitch.middleC`. Sample names require a non-whitespace character. `Track(_ name: String) { ... }` adds pre-order metadata and innermost track IDs without changing time or adding a render node.

Migration is complete in this task: only `Music.body: some Sound`, `Sound`, `SoundBuilder`, `CompiledSound`, and `SoundCompiler` remain; no Score aliases or `Music.score` entry remain.

### Exact time and rhythm

`MusicalTime` retains normalized non-negative `UInt64` rational storage and adds checked `multiplied(by: UInt64)` and `divided(by: UInt64)`. Multiplication throws overflow; zero division throws `MusicalTimeError.divisionByZero`. Successful results are exact.

`RhythmPattern` supports `ExpressibleByStringLiteral`. A literal retains its text until resolution and never traps on invalid input. Its `steps` getter preserves source compatibility by returning leaf values in depth-first source order. Explicit `init(_ value: String)` and `init(steps:)` validate eagerly and throw. Grammar is a nonempty ASCII-whitespace-separated sequence of `x`, `~`, or recursively nested `[ sequence ]` groups. Brackets are structural and are not leaves. A sequence divides its parent slot equally among its elements; a group occupies one such slot and recursively subdivides it. One internal parser emits each leaf's stable depth-first index and exact unit-cycle start/duration. Pattern source is bounded to 64 KiB UTF-8, 1,024 leaves, and nesting depth 32 before allocation or recursion; empty groups, unmatched brackets, invalid tokens, and exceeded bounds are typed failures. No other mini-notation operator is accepted. The modifier accepts `RhythmPattern`, with cycle defaulting to `.whole`.

`rhythm(pattern, cycle)` requires nonzero cycle and maps exact timed leaves into that cycle. Each hit clones each child event, adds its leaf onset, sets its leaf duration, and records its leaf index; rests emit nothing. Extent is at least the full cycle, preserving trailing rests. Nested modifiers apply inner-to-outer. `offset` adds to starts and extent. `repeated(count)` requires positive `Int`, copies the child sequentially at multiples of child extent, and multiplies extent. `fast` and `slow` require positive `UInt64` and divide or multiply starts, durations, and extent. Expansion and arithmetic are bounded before allocation.

Both pattern types provide `init(validating:)` to unambiguously request eager validation even for a literal argument. Swift may treat `RhythmPattern("...")` or `NotePattern("...")` as literal conversion rather than the throwing unlabeled String initializer. Use the labeled initializer at eager-validation boundaries. Literal equality compares retained source text; whitespace differences remain different declaration values even when they resolve to the same steps.

### Pitch, harmony, and expression

`NotePattern` uses the same bounded bracket structure and deferred/eager construction contract. Its throwing `steps` getter returns depth-first `[Pitch?]`, where nil is an explicit rest. Leaf tokens are `~` or scientific pitch names: A-G (case insensitive), optionally one ASCII `#` or `b`, followed by a decimal octave with optional minus sign. C4 is MIDI 60; enharmonic spellings resolve through the same arithmetic, and results must be 0...127. Structural, malformed-token, and out-of-range failures remain typed with leaf index or source offset where applicable. Numeric parsing rejects overflow rather than trapping.

`notes(_ pattern: NotePattern, cycle: MusicalTime = .whole)` maps exact timed leaves into the cycle. Each pitched leaf clones every child event, adds its onset, sets its leaf duration, replaces pitch, and records its leaf index. Rests clone no events; extent is at least the full cycle. Event limits are checked before expansion, and invalid patterns fail even on an empty subtree. Nested pattern modifiers expand inner-to-outer by these same rules.

`rhythm` and note-pattern overloads add defaulted `fileID: String = #fileID`, `line: Int = #line`, and `column: Int = #column` parameters without changing existing call syntax. They store a validated `SoundSourceAnchor` on every source in their subtree. Each emitted event also stores the zero-based lexical token index from the pattern expansion that owns the source anchor; rests emit no event. Nested pattern modifiers apply inner-to-outer, so the outermost pattern anchor and emitted step index win; other transforms preserve both. `CompiledSource.patternAnchor` remains present when a pattern emits only rests, and events resolve their row through `sourceID` rather than duplicating source provenance.

Pattern failures are exposed as `SoundCompilationError.invalidRhythm(RhythmPatternError)` and `.invalidNotes(NotePatternError)`. An unexpected thrown preparation error must remain an explicit failure (`unexpectedFailure(String)`), never a default sound.

`notes(_:)` requires a nonempty `[Pitch]` and assigns pitches cyclically in current event order. `transpose(_:)` requires pitched events and checked MIDI 0...127 results. `chord(_:)` requires pitched events and expands fixed intervals in order: `.major` = 0,4,7; `.minor` = 0,3,7; `.power` = 0,7; `.dominantSeventh` = 0,4,7,10. Expanded notes retain source, track, time, and expression.

`CompiledSoundEvent` exposes source ID, optional track ID, start, rhythmic duration, optional pitch, MIDI velocity, gate ratio, and an optional zero-based `patternStepIndex`. Rhythm and note-pattern expansion records the lexical token index for each emitted event; repeated, tempo, pitch, and other cloning transforms preserve it, while array-based `notes` clears it because no pattern text exists. Defaults are velocity 80 and gate 1. `Dynamic` maps `pp`, `p`, `mp`, `mf`, `f`, `ff` to documented fixed velocities. `dynamic` and `velocity` replace velocity; velocity requires 1...127. `gate` replaces gate and requires finite positive input. `staccato` multiplies current gate by 0.5. Expression never changes beat duration or extent.

### Source settings

`Tuning(referencePitch:frequencyHz:)`, `Envelope(attackSeconds:decaySeconds:sustainLevel:releaseSeconds:)`, `SampleRegion(startFraction:endFraction:)`, and `Unison(voices:detuneCents:)` have throwing initializers. Frequencies are finite positive; time and detune are finite nonnegative; normalized fields are 0...1; region start is less than end; unison is 1...16 voices. `CompiledSource` also exposes its optional pattern anchor; source ID remains the join key for events and client rows.

Tuning and envelope support both sources. Sample region supports only Sample; unison only Synthesizer. An incompatible source anywhere in the modifier subtree is a typed compilation failure. Repeated settings apply inner-to-outer, so outer replaces the same field. `CompiledSource` exposes snapshot ID, source kind, and explicit optional settings.

### Effects, mix, and render plan

`AudioEffect` is an immutable enum:

```swift
case equalizer(frequencyHz: Double, gainDecibels: Double, q: Double)
case filter(kind: FilterKind, cutoffHz: Double, resonance: Double)
case compressor(thresholdDecibels: Double, ratio: Double)
case distortion(drive: Double)
case delay(time: MusicalTime, feedback: Double, wet: Double)
case reverb(roomSize: Double, wet: Double)
case chorus(rateHz: Double, depth: Double, wet: Double)
```

Frequency, Q, rate, and ratio are finite positive, with ratio at least 1. Gain and threshold are finite. Resonance and drive are finite nonnegative. Delay time is nonzero. Feedback is 0..<1; wet, room size, and depth are 0...1. Invalid values fail compilation.

`CompiledRenderNode` cases are `source(sourceID:)`, `mix(inputs:)`, `effect(input:effect:)`, `gain(input:value:)`, `pan(input:value:)`, `mute(input:)`, `send(input:bus:level:)`, and `output(input:bus:)`. `CompiledSound.renderNodes` is dependency ordered and node IDs are array indices; `rootNodeIDs` names final main-signal roots and routed output sinks.

An `output` node is a terminal routing sink and cannot be an input to another render node. Parallel merging keeps output sinks as separate final roots and mixes only unrouted main-signal roots: zero main roots produce no mix, one passes through, and multiple produce one mix. Thus `Track { Sample("a").output("bus"); Sample("b") }` has the output sink and the unrouted sample as separate final roots and never mixes the sink back into the main signal.

Effects, gain, pan, mute, send, and output wrap a subtree only while it has no terminal output sink. Applying an otherwise valid one outside a subtree that already contains an output sink throws `SoundCompilationError.invalidParameter` describing processing after output; invalid scalar or name input may be rejected first by the same typed case. Processing must be declared before routing. Event transforms and source settings remain legal outside output because they alter events or descriptors without consuming a render root. Chained effects preserve source -> first -> second, while an effect on a multi-source Track produces sources -> mix -> effect. Gain is finite nonnegative, pan finite -1...1, send level finite nonnegative, and route names non-whitespace. Send preserves main flow and remains consumable while describing its side route.

### Compilation result and limits

`SoundCompiler.compile(_ music:)` and `compile(_ sound:)` return `CompiledSound` with sorted events, pre-order tracks and sources, dependency-ordered nodes, roots, and extent. Track and source IDs are snapshot-local zero-based traversal ordinals. Render node IDs are their indices in the dependency-ordered node array. Events sort by start then traversal order; expansions remain deterministic.

`SoundCompiler.Limits` has positive configurable depth, event, track, source, and node maxima. Every custom and package node counts toward depth. Typed `SoundCompilationError` covers invalid parameters, source capability, missing or overflowing pitch, musical-time failure, invalid names, and every bound. No failure returns partial output.

## Runtime Flows

```text
expand body within depth
  -> compile child fragments in declaration order
  -> transform wrapper's fragment
  -> merge siblings and assign IDs
  -> validate bounds, sort events, return CompiledSound
```

Tempo mapping remains a separate pure musical-time operation.

## State, Ownership, and Lifecycle

Declarations, parameters, and public results are immutable `Sendable` values. The compiler owns call-local mutable value buffers for fragment transforms, arrays, and ordinal assignment; none escape as shared mutable state. `CompiledSound` owns the finalized result. There is no cache, registry, task, retained pointer, or shutdown lifecycle.

## Failure, Concurrency, and Constraints

Declaration construction and client getter execution before a value returns are outside compiler limits. Once traversal resumes, bounds are checked before descent and expansion allocation. Effects and source settings remain descriptors; backend support and audible behavior cannot be verified here. Independent compiles and tempo conversions may run concurrently.

## Verification and Change Impact

| Contract | Behavioral evidence |
|---|---|
| Migration/composition | External Music and Sound bodies, branches, loops, empties, parallel siblings work; old Score symbols are absent |
| Rhythm | Parser failures, hits/rests, trailing extent, offset, repeat, fast, slow, nested order, overflow, event bound |
| Source provenance | Default call-site file/line/column, outermost-pattern and emitted-step precedence, rest indices, transform preservation, all-rest anchors, unchanged unannotated calls |
| Pitch/harmony | Notes cycle, transpose MIDI bounds, all chord intervals/order, unpitched errors |
| Expression | Dynamic, velocity/gate validation, stacked staccato fields with unchanged extent |
| Sources | Both descriptors, common settings, region/unison capability success and failure |
| Effects/mix | Each effect success/failure; source-chain and mix-effect order; gain, pan, mute, send, output, roots, subtree scope; routed and unrouted siblings remain separate; every processing-after-output form fails |
| Track | Unmodified wrapper preserves events/nodes; nested and empty metadata remains |
| Bounds/determinism | Depth, events, tracks, sources, nodes fail without output; IDs and event order repeat |
| Foundation | Rational operations remain checked; one compiled sound maps through distinct tempi unchanged |

The focused suite runs after stable integration. Deferred operations require explicit semantics, errors, bounds, and output evidence before implementation.

## Nested Mini-Notation and Gain Patterns

The shared internal parser owns only whitespace-separated leaves and recursively nested `[]` subdivisions. Each outer child has equal duration; a group divides that child's duration equally among its children. Depth-first leaf indices include rests but exclude brackets. Bounds are 64 KiB UTF-8 input, 1,024 leaves and 32 group levels; empty input/groups, unmatched brackets and exceeded limits fail with typed errors before unbounded allocation. Other mini-notation operators are not accepted. RhythmPattern and NotePattern retain rawValue, deferred literals, eager validation and flattened `steps` values; the compiler consumes exact timed leaves. Existing flat syntax retains its timing. Group syntax extends the earlier flat step descriptions in this document.

A timed leaf carries exact nonnegative rational start and positive duration. Resolution starts with the modifier's positive cycle and recursively divides each parent slot using MusicalTime checked arithmetic. Rhythm and notes clone child events at each non-rest leaf onset, use that leaf duration, and preserve the leaf index in patternStepIndex. Extent preserves the full cycle including trailing rests. Expansion uses existing compiler event limits before allocation.

`GainPattern: ExpressibleByStringLiteral` accepts finite nonnegative Double leaves and the same bracket grammar; zero is silence, and `~` is invalid (use zero). `.gain(_ pattern: GainPattern, cycle: MusicalTime = .whole)` samples the pattern at each current event start modulo the cycle, multiplies `CompiledSoundEvent.gain` (default 1), and holds that value for the voice lifetime. Sampling uses exact rational boundaries, never floating-point time. Stacked patterns multiply; nonfinite products fail. Empty subtrees still validate patterns/cycles. Events and extent are not added or removed by gain patterns. Time transforms after gain assignment preserve the assigned value; applying the pattern after a time transform samples the transformed onset, consistent with inner-to-outer modifier order.

The existing `.gain(Double)` remains an ordered post-mix render node. Patterned gain is per-voice performance gain before mixing and effects; the distinction preserves the existing scalar API contract. Clients must render CompiledSoundEvent.gain, validate representability in their PCM format and retain zero-gain events as musical metadata. Gain patterns do not replace rhythm/note source anchors or leaf indices.

```text
raw pattern -> bounded bracket parser -> exact timed leaves
rhythm/notes -> cloned events + leaf index
gain pattern + current event onset -> exact cycle phase -> event.gain
compiled events -> client per-voice gain -> existing ordered mix graph
```

Tests own nested/nonuniform timing, rest/token provenance, flat compatibility, bracket failures and bounds, gain onset sampling with unequal pattern counts and repeated cycles, exact boundary arithmetic, stacked/zero/nonfinite gain, modifier order and preservation through transforms. Parent and MusicPlaygournd renderer contracts must be rechecked when event fields or pattern timing change.

## Domain Parameter Patterns

Numeric parameter patterns remain domain-specific public values. Parser and exact phase machinery may be reused internally, but that implementation reuse does not create a public generic pattern abstraction.

Existing `GainPattern`, `.gain(_ pattern: GainPattern, cycle:)`, its source syntax, flattened `steps`, error cases, onset multiplication, and scalar `.gain(Double)` render-node semantics remain compatible. `GainPattern.fast(_ factor: UInt64)` and `.slow(_ factor: UInt64)` return deferred transformations without parsing a literal at construction. Fast advances exact phase by the factor within the modifier cycle; slow expands the cycle by the factor. Zero factors and arithmetic overflow are typed gain-pattern failures when resolved.

`PanPattern` is a separate `ExpressibleByStringLiteral` value with retained `rawValue`, deferred literal parsing, throwing eager dynamic validation, flattened `steps`, and the same exact nested `[]` grammar and 64 KiB/1,024-leaf/32-depth bounds. Every leaf must be a finite `Double` in `-1...1`; rests are invalid. Its integer `fast` and `slow` transformations follow the same deferred exact-phase contract and return typed pan-pattern failures.

`.pan(_ pattern: PanPattern, cycle: MusicalTime = .whole)` samples transformed phase at each current event onset. The outermost pan pattern replaces earlier event-pan values; later time transforms preserve the assigned value while earlier time transforms affect sampling. `CompiledSoundEvent.pan` is optional and defaults to nil so sounds without a pan pattern preserve prior centered PCM byte for byte. A resolved value, including explicit zero, uses the existing equal-power cosine/sine law. Existing `.pan(Double)` remains an ordered post-mix render node with unchanged behavior. Patterned pan is per voice before source mixing and is copied as optional client event metadata. Pattern resolution validates empty subtrees and positive cycles and never adds, removes, or retimes events. Rational speed ratios and additional grammar belong to the following pattern/time sprint.

Tests own GainPattern/PanPattern deferred validation and parser bounds, integer fast/slow exact phase, existing gain source/error/scalar compatibility, pan cycle boundaries and last-pattern precedence, modifier order, nil-default preservation versus explicit-zero equal-power behavior, invalid domains/overflow, CompiledSoundEvent and client-event optional pan metadata, stereo PCM direction/power, and unchanged scalar pan rendering.

## Rational Pattern Rates

`PatternRate` is the public time-domain value for an exact positive pattern speed. It is not a generic parameter-pattern abstraction. `PatternRate(numerator:denominator:)` and `PatternRate(validating value: Double)` validate eagerly and throw `PatternRateError` for zero, negative, nonfinite, zero-denominator, or reduced values that cannot fit its bounded `UInt64` rational representation. There is no unlabeled throwing Double initializer because Swift would select literal conversion for direct literal syntax and make its eager behavior ambiguous. `ExpressibleByFloatLiteral` retains the same validation result, so direct construction such as `PatternRate(1.5)` and contextual source such as `.fast(1.5)` are deferred and report a typed domain-pattern compilation failure only when resolved. Dynamic input that must fail at construction uses `try PatternRate(validating: value)`.

A `Double` rate uses its locale-independent shortest round-trip decimal spelling as the musical value, including checked scientific-notation expansion, then reduces that decimal exactly into the bounded rational representation. This makes ordinary source values compose musically: `1.1` is `11/10`, `1.2` is `6/5`, and their product is exactly `33/25`. It does not preserve the hidden IEEE binary fraction and does not round to a fixed decimal precision. Computed values whose canonical spelling exposes floating-point residue retain that residue exactly; values or powers of ten that cannot be represented within the rational bound fail explicitly.

`GainPattern` and `PanPattern` add `fast(_ rate: PatternRate)` and `slow(_ rate: PatternRate)` while retaining the existing `UInt64` overloads unchanged. An integer literal therefore continues to select the existing overload, and a fractional literal selects `PatternRate`. Fast resolves the pattern cycle as `cycle / rate`; slow resolves it as `cycle * rate`. Chained transforms compose normalized rational factors exactly and defer parsing of pattern source text. Invalid deferred rates and checked-arithmetic overflow map to the receiving domain's typed compilation error. These operations change only phase sampling: values, leaf indices, event onsets, event counts, sound extent, scalar modifiers, and source provenance remain unchanged.

```text
integer factor -> existing UInt64 overload ----\
fractional literal -> deferred PatternRate p/q --+-> deferred phase scale -> onset sampling
validating Double / explicit p/q -> eager rate --/
```

Focused tests distinguish integer-overload source compatibility from fractional-literal selection; prove exact `3/2`, canonical-decimal `1.1 * 1.2 == 33/25`, scientific notation, reciprocal fast/slow, chained reduction and cycle-boundary sampling for gain and pan; reject zero, negative, nonfinite, zero-denominator and unrepresentable decimal/rational values through typed failures; and cover checked composition overflow without parsing or retiming events. Alternation grammar, reverse/repetition, independent track cycles, and typed musical parameter units remain separate work items.

## Cycle Mini-Notation

The bounded internal parser extends its SwiftMusic notation without exposing a Strudel AST. Whitespace still sequences slots, `[]` still subdivides one parent slot, and the following ASCII forms are added:

| Form | Meaning |
|---|---|
| `<a b>` | Select top-level alternative `a` on one pattern cycle and `b` on the next, then repeat that finite alternation period. An alternative may be a leaf or a bracketed subdivision. |
| `token*count` | Repeat one leaf token `count` times sequentially inside that leaf's slot; count is a positive decimal integer. |
| `~` | Preserve a timed rest in rhythm and note patterns. Gain and pan continue to reject rests. |
| `C4,E4,G4` | Emit the comma-separated pitches simultaneously from one NotePattern leaf. Empty members and non-pitch members fail. Commas remain invalid in other domains. |

Operators are separated structurally: angle brackets cannot be embedded in a leaf, repetition is a leaf postfix, and comma separation belongs only to a note leaf before its optional repetition suffix. Existing pitch accidentals and negative octaves keep their current token meaning. Existing flat and nested-bracket source retains identical timing and values.

The parsed program owns lexical leaf indices and UTF-8 byte ranges. Repetition occurrences share the repeated leaf's lexical index; simultaneous notes share their chord leaf's index; alternation branches retain their own source indices. Every pattern-source failure exposes its exact zero-based UTF-8 byte offset. `RhythmPatternError`, `NotePatternError`, `GainPatternError`, and `PanPatternError` add `offset` to every token-carried invalid/value/range case, including note pitch range, gain negative/nonfinite, and pan nonfinite/out-of-range failures. Parser input-length, leaf-count, depth and timing/period-overflow cases also carry the first byte that violates the bound or the structural operator whose resolution overflowed; empty input is position zero, and existing bracket/group cases retain their delimiter offsets. Associated `offset` arguments default to zero only for source construction compatibility, while every parser-emitted error supplies the real location. Each domain error exposes `utf8Offset`, and equality includes location rather than ignoring it. This intentional 0.2 API change alters associated-value pattern-matching arity. General non-pattern `SoundParameterError` remains outside this source-location contract. Deferred literals report the same located typed error during compilation as eager validation reports directly.

An alternation program has a finite natural period measured in pattern cycles. A sequence or subdivision containing periodic siblings has their checked least-common-multiple period. An alternation with `n` alternatives has `n * LCM(child periods)` as its checked natural period; parent cycle `c` selects alternative `c % n` and evaluates that child at local cycle `c / n`. Thus `<a <b c>>` resolves as `a, b, a, c`, rather than losing the inner branch under a plain LCM. Resolution fails before event allocation if the natural period or the fully realized leaf occurrences across that period exceeds 1,024; the existing 64 KiB input and 32-level nesting limits still apply, and repeat expansion counts toward the realized limit. `steps` presents the fully realized natural period in cycle and time order, with simultaneous pitches adjacent and repeated leaves repeated, so existing syntax remains a one-cycle special case.

RhythmPattern and NotePattern compile every cycle in their natural period at exact offsets from zero. Their minimum extent becomes `cycle * naturalPeriod`; rests retain that extent, and simultaneous notes emit same-start/same-duration events. Expansion checks `SoundCompiler.Limits.maximumEvents` before allocation. `patternStepIndex` remains the lexical leaf index, including repeated and simultaneous emissions.

GainPattern and PanPattern do not add events or extent. For each existing event onset they compute the exact absolute cycle quotient and in-cycle phase, select the alternation branch by quotient modulo natural period, then sample its timed leaf. An event outside the first cycle can therefore observe later alternatives without floating-point time. Empty subtrees still validate the complete program.

```text
source -> bounded program + lexical byte ranges + finite natural period
       -> rhythm/notes: expand every syntactic cycle -> events + period extent
       -> gain/pan: event onset quotient/phase -> selected value, no new event
siblings with shorter extents ---------------------------------> P02.3
```

This increment does not repeat a shorter sibling track to another sibling's or the renderer's extent. Independent track cycles and bounded host-window filling remain P02.3. A native client may reject the resulting finite extent under its existing duration/beat limits; it must not truncate the alternation or claim that rendering only its first cycle is complete.

Focused tests cover flat and `[]` compatibility; two- and nested-period branch order over all cycles; checked period/realized-leaf bounds; token and rest repetition timing; simultaneous note pitch/start/duration and MIDI bounds; lexical indices; gain/pan sampling after the first cycle; empty/all-rest extent; pre-allocation event limits; and exact UTF-8 offsets with multibyte prefixes for syntax, invalid tokens, note pitch range, gain value, pan value and parser-bound failures. Client integration proves that a complete in-bound alternation reaches event metadata and PCM, while an out-of-bound native loop fails explicitly.

## Native Source Performance

P03 turns existing source descriptors into audible native behavior while keeping musical compilation independent of file and audio I/O. SwiftMusic validates and emits immutable source/event policy; MusicPlaygournd resolves files, allocates voices, and renders PCM. No compiler API reads a file, opens an audio device, or silently substitutes a built-in sound.

Existing `Envelope` remains the amplitude ADSR descriptor and its current initializer remains source compatible. Additive defaults describe linear attack/decay/release curves and release anchored at the gated note end. `EnvelopeCurve` supports bounded linear and exponential shapes; `EnvelopeReleaseAnchor` selects gated note end or ungated event end. Attack and decay begin at event onset, sustain follows decay, and release begins only at the selected anchor. The P02.4 `EnvelopePattern` may replace the source envelope per event onset; outermost assignment wins. `pitchEnvelope(_:depth:)` and `filterEnvelope(_:depth:)` reuse the same normalized ADSR contour with signed semitone depth, returning to zero modulation after release. Static source settings remain the fallback when an event has no patterned override.

`SourceFilter` owns low-pass, high-pass, or band-pass kind, positive cutoff, positive resonance Q, and `FilterSlope` of 12 or 24 dB per octave. `.filter(_:)` applies it to source descriptors; the P02.4 cutoff pattern supplies an optional per-event cutoff. Cutoff must be finite and positive at compilation and below the native Nyquist frequency at rendering. A cutoff pattern without a source filter is a typed compilation failure after the complete modifier subtree is known, so modifier order does not create a false failure. Existing `AudioEffect.filter` remains a post-mix render node owned by P04 and is not reinterpreted as this per-voice source filter.

```text
oscillator/sample frame
  -> sample traversal or pitch + pitch envelope
  -> per-voice source filter + filter envelope
  -> amplitude ADSR -> velocity -> event gain/pan
  -> source mix -> existing ordered render nodes
```

`Sample(_ name:)` keeps its named built-in behavior. Additive file and bank initializers produce descriptor-only source kinds. `SampleBank` contains an ordered, nonempty set of unique nonblank keys and explicit file URLs; it never relies on directory enumeration order. `SampleSelectionPattern` is a separate bounded string domain whose leaves select bank keys at exact event onsets. Missing keys fail compilation, while unreadable/unsupported files fail native preparation. Existing `SampleRegion` crops the selected decoded asset before traversal. Additive reverse and positive playback-rate source settings change traversal inside that region and do not change musical event onset, gate, or extent; pitch-preserving stretch remains P06.

The native client decodes actual local PCM through its injected sample-loading protocol. It accepts mono or stereo finite PCM, converts supported source sample rates to the required output rate, caches only assets selected by the current immutable render, and rejects unsupported formats, channels, nonfinite samples, files longer than the prepared-loop duration ceiling, or more than 32 distinct selected assets. Failure is typed and retains the previously adopted loop. Built-in kick/snare/closedHat generation remains available only for their existing names and is never a fallback for a failed file or bank reference.

`VoicePolicy` is an optional source setting. Nil preserves the current behavior of rendering every compiled overlap within existing event bounds. `.monophonic` permits one active voice; `.polyphonic(limit:stealing:)` requires a positive limit no greater than the compiler event limit. `VoiceStealing` supports oldest and quietest, with onset then compiled event order as deterministic ties. A nonblank choke group may span sources: a new onset terminates older active voices in that group with the renderer's bounded click-suppression ramp. Release tails count as active voices; a stolen or choked voice does not continue its release. These policies do not delete compiled musical events or their provenance.

Compiler tests own initializer/domain validation, inner-to-outer replacement, event-onset pattern selection, empty-subtree failure, capability errors, deterministic bank keys, voice policy and choke metadata, and unchanged legacy descriptors. Native tests own oscillator frequency, exact ADSR segment boundaries and release horizon, pitch/filter modulation, 12/24 dB filter response, resonance stability, real temporary-file decode, stereo preservation, selection/region/reverse/rate traversal, typed I/O failures and limits, deterministic stealing/choke output, nil-policy PCM compatibility, and nonzero hardware playback of a prepared result. All new tests use Swift Testing.
