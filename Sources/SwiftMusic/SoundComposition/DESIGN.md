# SoundComposition

## Purpose and Scope

SoundComposition owns the path from declarative `Sound` through six modifier categories to immutable beat events and render-plan descriptors. Its parent is the [SwiftMusic module](../DESIGN.md). It has no children.

| Category | Supported operations |
|---|---|
| Rhythm | `rhythm(_:cycle:)`, `offset(_:)`, `repeated(_:)`, `fast(_:)`, `slow(_:)` |
| Pitch and harmony | `notes(_:)`, `transpose(_:)`, `chord(_:)` |
| Expression | `dynamic(_:)`, `velocity(_:)`, `gate(_:)`, `staccato()`, pattern `gain(_:cycle:)` |
| Source settings | `tuning(_:)`, `envelope(_:)`, `sampleRegion(_:)`, `unison(_:)` |
| Audio effects | `effect(_:)` with EQ, filter, compressor, saturation, distortion, delay, reverb, chorus |
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

Sources are `Sample(_ name: String)` and `Synthesizer(_ waveform: Waveform)`. Each initially emits one event at zero with quarter-note duration. Sample is unpitched; Synthesizer initially uses `Pitch.middleC`. Sample names require a non-whitespace character. `Track(_ name: String) { ... }` adds pre-order metadata and innermost track IDs without changing time. P04.3 adds one boundary render node for nonempty main-signal content; an empty Track remains metadata-only.

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
case saturation(drive: Double)
case distortion(drive: Double)
case delay(time: MusicalTime, feedback: Double, wet: Double)
case reverb(roomSize: Double, wet: Double)
case chorus(rateHz: Double, depth: Double, wet: Double)
```

Frequency, Q, rate, and ratio are finite positive, with ratio at least 1. Gain and threshold are finite. Resonance and drive are finite nonnegative. Delay time is nonzero. Feedback is 0..<1; wet, room size, and depth are 0...1. Invalid values fail compilation.

`CompiledRenderNode` cases are `source(sourceID:)`, `mix(inputs:)`, `effect(input:effect:)`, `gain(input:value:)`, `pan(input:value:)`, `mute(input:)`, `track(input:trackID:)`, `send(input:bus:level:)`, and `output(input:bus:)`. `CompiledSound.renderNodes` is dependency ordered and node IDs are array indices; `rootNodeIDs` names final main-signal roots and routed output sinks.

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

The parsed program owns lexical leaf indices and UTF-8 byte ranges. Repetition occurrences share the repeated leaf's lexical index; simultaneous notes share their chord leaf's index; alternation branches retain their own source indices. Every pattern-source failure exposes its exact zero-based UTF-8 byte offset. `RhythmPatternError`, `NotePatternError`, `GainPatternError`, and `PanPatternError` add `offset` to every token-carried invalid/value/range case, including note pitch range, gain negative/nonfinite, and pan nonfinite/out-of-range failures. Angle-bracket failures have distinct unmatched-opening and unmatched-closing cases; a malformed/missing/nonpositive/overflowing `*count` is `invalidRepetition(offset:)`. Parser input-length, leaf-count and depth cases carry the first byte that violates the bound; empty input is position zero, and existing bracket/group cases retain their delimiter offsets. `timingOverflow(offset: Int? = nil)` carries the structural operator for parser period/timing overflow and nil for rate/phase/transform arithmetic that has no source byte. Other associated source offsets default to zero only for construction compatibility, while every parser-emitted error supplies the real location. Each domain error exposes `utf8Offset: Int?`; it returns the exact value for source-backed failures and nil for transform failures. Equality includes location rather than ignoring it. This intentional 0.2 API change alters associated-value pattern-matching arity. General non-pattern `SoundParameterError` remains outside this source-location contract. Deferred literals report the same located typed error during compilation as eager validation reports directly.

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

## Pattern Transforms and Explicit Cycles

RhythmPattern, NotePattern, GainPattern and PanPattern remain separate public domains and gain the same time operations without a public generic facade. `fast(_ rate: PatternRate)` and `slow(_ rate: PatternRate)` scale exact in-cycle time; existing UInt64 overloads remain where already published. `phase(_ offset: MusicalTime)` advances sampling by an exact nonnegative offset modulo the supplied pattern cycle. `reversed()` mirrors leaf starts and order inside each selected cycle while retaining lexical indices and alternation-cycle order. `repeated(_ count: UInt64)` requires a positive count and fits that many successive local pattern cycles into one caller cycle; alternation advances for each local cycle, and the resulting natural period is reduced exactly. Operations compose in declaration order, defer literal parsing, and fail with the receiving pattern's typed rate/time/overflow error before unbounded realization.

Pattern transforms never retime a child Sound by themselves. Existing `Sound.fast`, `Sound.slow`, `Sound.repeated(_:)`, and `offset(_:)` retain their finite event/extent semantics. In particular, `Sound.repeated(2)` remains two explicit copies and is not reinterpreted as an infinite loop.

Every `rhythm(_:cycle:)` and `notes(_:cycle:)` pattern declaration creates an internal recurrence program. Its exact generating period is `cycle * naturalPatternPeriod`. A gain or pan pattern encountered later in the existing inner-to-outer modifier order, after a generator has produced its current events, samples those generated onsets and contributes its transformed natural period to that recurrence by checked rational least common multiple. Thus `source.rhythm("x", cycle: .whole).gain("<1 0.5>")` has an eight-beat live period and compiles gains 1 and 0.5 on successive onsets. Conversely, `source.gain("<1 0.5>").rhythm("x", cycle: .whole)` samples the primitive onset before rhythm expansion, then rhythm inherits that resolved gain exactly as finite compilation does; it remains gain 1 and the numeric period does not become recurrence. The same ordering rule applies to pan. Sibling fragments retain separate recurrence identities during analysis so a shorter track is never stretched to a longer sibling. Bare sources, array-based notes, Tracks and groups without a generating pattern remain finite.

The existing `compile(_:)` remains the finite API and emits the current bounded event list/extent. Additive `compile(_:liveLoop:)` accepts `LiveLoopPolicy(beatsPerBar:maximumBeats:)`. The policy validates a positive integer bar and positive exact maximum, analyzes all active recurrence and finite one-shot extents, and chooses the least exact whole-bar window that contains the finite extent and is a whole multiple of every active recurrence period. If rational common-multiple arithmetic, the requested window, or event expansion exceeds compiler limits, compilation fails before output.

The existing single compilation traversal captures an internal immutable event program, then live compilation analyzes its periods and emits events through the chosen horizon. It executes modifiers at their existing inner-to-outer stage: values resolved before a generator are inherited, while generator and later onset-dependent operations are evaluated for each occurrence. It never copies an already compiled event whose parameter values may be cycle-dependent. `CompiledSound` returned by live compilation is fully materialized with the chosen window as extent; renderers need no pattern interpreter or recurrence resampling API. All-rest recurring programs affect the window without inventing events. Event ordering, source provenance and lexical indices remain deterministic.

The implementation extends the existing `_SoundCompilationContext.visit` pass and `_SoundFragment`; it does not traverse a second lowered Sound tree. The current pass still evaluates each custom `Sound.body` once, validates and mutates the finite event result, and allocates each `CompiledSource`, `CompiledTrack` and render-graph node once. In parallel, each fragment captures one immutable internal `_LiveEventProgram`: finite event seeds, a rhythm/note generator with a child and validated `_SoundModifier`, an ordered event modifier with a child and validated `_SoundModifier`, or a group of independent child programs. Track identity remains embedded in seeds and group composition does not merge source identities. This internal event-only program contains no render nodes and emission never calls `Sound.body` or allocates graph/source identity.

The existing `apply(_:to:sourceRange:)` remains the finite semantic authority and records the corresponding live-program operation only after successfully validating and applying that modifier. `_SoundCompilationContext.applyEvents` reuses the same event-only modifier implementation during canonical evaluation. A first generator wraps the already resolved finite child seeds, so pre-generator gain/pan stays baked. Gain/pan after a generator records an onset sampler. Live emission first materializes the entire checked common sampler period and resolves every onset-dependent value through `applyEvents`; only then may it copy those proven-periodic final values through the larger host horizon. It never copies an unresolved first-cycle parameter value. Offset and Sound fast/slow record exact event/time operations when recurrence exists. Program period analysis computes the checked common window, and `emit(through:limits:)` walks only `_LiveEventProgram` and returns final events under the existing count limit.

For nested rhythm/note generators, analysis first computes the checked common period of the child recurrence and outer pattern. It emits every child occurrence within that one bounded common period, then applies the outer generator's canonical leaf offsets to each child occurrence in the same leaf-major, pitch-major, original-event order as finite compilation. The outer generator is a Cartesian modifier of those child occurrences, not an independent sibling stream and not a one-time transform of only the child's first occurrence. Resulting starts are normalized exactly into the half-open common period and deterministically sorted, so an offset crossing its end is represented at the equivalent beginning rather than lost; no unbounded stream is materialized. An inner four-beat `x` plus outer four-beat `x x` produces beats 0 and 2. An inner eight-beat program at beats 0 and 4 plus the same outer pattern produces 0, 2, 4 and 6. An inner three-beat `x` plus outer four-beat `x x` has common period 12 and produces 0, 2, 3, 5, 6, 8, 9 and 11, rather than only 0 and 2. If the inner eight-beat program came from `rhythm("x").gain("<1 0.5>")`, an outer four-beat `x` preserves events 0/gain 1 and 4/gain 0.5. Array `notes([Pitch])` remains an ordered finite assignment rather than a recurrence generator or independent clock: it assigns by the canonical current event order, the assigned pitches repeat with that enclosing generator template, and its array count does not lengthen the recurrence period. `NotePattern` remains the API for a pitch sequence whose own pattern period participates in live recurrence.

Sound `repeated(count)` is a stage boundary that preserves its finite meaning without layering several indefinitely recurring children. It snapshots the current finite event template and its current finite extent after all inner modifiers have run, serially copies that template `count` times at exact extent offsets, and replaces the child's recurrence with one recurrence template whose canonical length is `finiteExtent * count`. Values already sampled by inner gain/pan operations are copied unchanged and their future clocks do not survive this boundary; onset samplers applied outside `repeated` sample the copied onsets and contribute their own period. The resulting recurrence period is the checked rational least common multiple of the canonical repeat-template length and only later onset-sampler periods. Therefore `rhythm("x").gain("<1 0.5>").repeated(2)` has an eight-beat live template with gains `1, 1`, repeating `1, 1`; `rhythm("x").repeated(2).gain("<1 0.5>")` has the same eight-beat template length but gains `1, 0.5`, repeating `1, 0.5`. Neither form overlays two continuous four-beat generator streams. If the inner finite pattern already spans eight beats, repeating it twice produces a sixteen-beat canonical template.

Offset follows the same inner-to-outer stage order. Applied to an active recurrence, it shifts that recurrence's canonical phase exactly and normalizes generated occurrences modulo its period, including the preceding occurrence needed for a boundary-crossing duration; it does not add a second stream. Applied before any generator, or after `oneShot()` has cleared recurrence, it is an absolute finite delay at that stage. If no later generator appears, that delayed finite or one-shot source is never wrapped and is emitted once only when its finite onset lies in the selected live window. A later outer rhythm/note generator consumes the delayed finite seed, creates a new recurrence, and therefore normalizes the resulting onset into its composed canonical period. Consequently `Sample("x").offset(.whole).rhythm("x")` has its seed at beat 4 before the outer generator and its live canonical onset at beat 0 in the four-beat recurrence; this does not create a separate finite delayed event.

`CompiledSound.playbackMode` is `.finite` for `compile(_:)` and `.seamlessLoop` for `compile(_:liveLoop:)`. Finite events retain the existing extent and client-clipping contract. A seamless-loop event keeps its full gated musical duration when its onset is inside the canonical window and its end crosses the window boundary; the compiler does not shorten it, duplicate it at beat zero, or change its lexical identity. P02.3 admits a crossing duration no greater than the selected window, which makes every event at most two bounded render segments; a longer overlapping duration fails with a typed live-window error instead of truncating. Later voice/tail work may widen that bound only with corresponding allocation and overlap evidence.

`Sound.oneShot()` is the explicit opt-out for a patterned subtree. It clears recurrence behavior while retaining its complete finite pattern events. A later outer rhythm/note pattern creates a new recurrence, preserving inner-to-outer order. Sound fast/slow scale program time and recurrence periods; offset follows the recurring-versus-finite rule above while preserving its exact finite behavior under `compile(_:)`; Sound repeated uses the canonical finite-template rule above, and `.oneShot().repeated(count)` is the way to keep exactly that many nonrecurring copies in a live compilation.

```swift
Track("drums") {
    Sample("kick").rhythm("x ~ x ~")
}
                                   // rhythm continues on its own four-beat cycle

Sample("crash").offset(.whole)   // finite one-shot; never filled across the window
Sample("fill").rhythm("x ~").oneShot().repeated(2) // exactly two live copies
```

Compiler tests prove all four domain transforms over flat, nested and alternating programs; exact phase/reversal/repetition order; zero/overflow failures; byte-for-byte-equivalent finite compile behavior; automatic rhythm/note periods and nested LCM composition; post-generator gain/pan alternation and fractional-rate contributions; the contrasting pre-generator inherited value; both gain/repeated orderings and their future eight-beat sequences; a twice-repeated eight-beat pattern yielding a sixteen-beat template; nested-generator Cartesian order; source/render-node counts independent of occurrence count; one evaluation of a custom body; complete onset resampling; recurring offset phase without duplicate streams; finite and terminal-oneShot offset without wrap; pre-generator offset normalized only when a later outer generator establishes recurrence; all-rest recurrence; oneShot ordering; finite repeated behavior; deterministic output; no recurrence on bare siblings; preserved full duration and lexical identity for one boundary-crossing note; and typed window/event/duration overflow. Native rendering and seamless playback of the fully compiled window belong to the Rendering contract.

## Typed Pitch, Cutoff, and Envelope Patterns


P02.4 adds domain-specific values where Swift has no suitable unit type: `Frequency(hertz:)` requires a finite positive Double, `Decibels(value:)` and `Semitones(value:)` require finite signed Doubles. Their labeled throwing initializers avoid literal-overload ambiguity. Wall-clock envelope input uses the standard-library `Duration`; a new labeled `Envelope(attack:decay:sustainLevel:release:)` converts nonnegative, finitely representable durations into the existing public seconds fields, so the current `attackSeconds` initializer and equality remain source compatible. `MusicalTime` remains the only beat-domain value and adds `beats(_:)` plus checked `bars(_:beatsPerBar:)`; bars require an explicit positive meter and reduce to exact quarter-note beats rather than introducing a meter-dependent stored duration. Typed `Frequency` and `Decibels` overloads construct existing `Tuning`, equalizer and compressor descriptors without changing their stored Double cases.

`PitchPattern`, `CutoffPattern`, and `EnvelopePattern` are separate immutable domains and reuse only the bounded internal mini-pattern/timing machinery. `PitchPattern` is a string literal of finite signed semitone leaves and also accepts an eagerly validated `[Semitones]`. `CutoffPattern` is a string literal of finite positive hertz leaves and also accepts `[Frequency]`. `EnvelopePattern` accepts `[Envelope]` for a flat typed sequence, or `init(_ notation: String, values: [String: Envelope])` for brackets, alternatives and repetition over caller-named typed envelopes; every non-rest token must resolve in the nonempty value map, and `~` is invalid. This avoids a new punctuation grammar for four envelope fields. All three domains expose the P02.3 `fast`, `slow`, `phase`, `reversed` and `repeated` operations, the 64 KiB/1,024-leaf/32-depth bounds, exact UTF-8 source errors for textual input, and typed nil-location failures for typed-value or transform errors. There is no public generic pattern protocol or type-erased parameter container.

```swift
let twoBars = try MusicalTime.bars(2, beatsPerBar: 4)
let pitch: PitchPattern = "0 <7 12>"
let cutoff: CutoffPattern = "400 <800 1600>"
let tight = try Envelope(
    attack: .milliseconds(5), decay: .milliseconds(80),
    sustainLevel: 0.5, release: .milliseconds(120)
)
let envelopes = try EnvelopePattern("tight [tight open]", values: [
    "tight": tight,
    "open": try Envelope(
        attack: .milliseconds(20), decay: .milliseconds(200),
        sustainLevel: 0.8, release: .milliseconds(500)
    )
])

Synthesizer(.saw)
    .notes("C3 E3 G3")
    .transpose(pitch, cycle: twoBars)
    .lowPass(cutoff, cycle: twoBars)
    .envelope(envelopes, cycle: twoBars)
```

`transpose(_:cycle:)` requires every current event to have a base pitch, samples at its onset and adds the selected semitone value to `CompiledSoundEvent.pitchOffsetSemitones`, whose default is zero. Whenever any modifier writes or expands pitch—including patterned or static transpose, array notes, NotePattern, and chord—the compiler validates the effective fractional MIDI value `Double(pitch.midiNote) + pitchOffsetSemitones` as finite and within 0...127. An unpitched event or out-of-range effective value is a typed compilation failure; values are never clamped. Existing `transpose(Int)` continues to change the base seven-bit `Pitch` while retaining the patterned offset. Thus a retained +1 offset followed by `notes([Pitch(midiNote: 127)])`, a C4 chord expansion reaching past 127, or an equivalent NotePattern replacement fails at the pitch-writing modifier. Fractional offsets remain metadata for P03 native pitch rendering.

`lowPass(_:cycle:resonanceQ:slope:)` is explicitly a per-voice low-pass declaration, avoiding an implicit filter-kind choice. P02.4 `SourceFilter` stores the existing `FilterKind.lowPass`, positive finite resonance Q and `FilterSlope` of 12 or 24 dB per octave; cutoff exists only on each sampled `CompiledSoundEvent.cutoffHz`, so the descriptor has no duplicate or guessed base cutoff. The modifier replaces the subtree's source-filter descriptor and current event cutoffs and uses no post-mix `AudioEffect.filter`. Other `FilterKind` cases become constructible only with their owning P03 contract.

`envelope(_:cycle:)` samples a complete `Envelope` into `CompiledSoundEvent.envelope`; the current static `.envelope(Envelope)` remains the source fallback. An outer static envelope clears inner event overrides, while an outer envelope pattern replaces them; this preserves inner-to-outer value replacement. `_LiveEventProgram` records the outer clear operation so canonical emission cannot restore an inner envelope value. Period analysis deliberately retains the complete periods of earlier declared envelope, cutoff, pitch, gain and pan samplers even when a later modifier replaces or clears their values; declaration-order replacement is not also a clock-pruning optimization. The outermost low-pass declaration likewise replaces filter configuration and event cutoff values while earlier sampler periods remain in the checked live LCM.

Each parameter pattern preserves rhythm/note `patternAnchor`, `patternText` and `patternStepIndex`; P02.4 adds no parameter-provenance placeholder. It never creates, removes, retimes or relabels an event. Before a generator it resolves against current finite onsets and contributes no future clock. After a generator it is an ordered `_LiveEventProgram` sampler, contributes its complete transformed natural period to the checked live LCM, and is re-evaluated over the full canonical sampler period before periodic values are copied. `Sound.repeated` closes these clocks under the P02.3 template rule. Empty/all-rest subtrees still validate patterns, units and cycles.

P02.4 ends at immutable compiler metadata. Until P03 implements native pitch offset, low-pass and per-event envelope DSP, LoopRenderer must reject any compiled sound using these new fields with a typed unsupported-feature error before PCM allocation; it must not ignore metadata or return unchanged audio. Existing sounds whose new fields retain defaults render byte-for-byte through the prior path. Compiler tests own unit conversion, eager/deferred and located failures, typed/text parity, transform order, static-versus-pattern envelope/filter replacement, provenance preservation, pre/post-generator clocks, repeated closure, live LCM and bounds. Client tests own explicit rejection of every new nondefault field and unchanged rendering for defaults. All tests use Swift Testing.

## Native Source Performance

P03 turns existing source descriptors into audible native behavior while keeping musical compilation independent of file and audio I/O. SwiftMusic validates and emits immutable source/event policy; MusicPlaygournd resolves files, allocates voices, and renders PCM. No compiler API reads a file, opens an audio device, or silently substitutes a built-in sound.

Existing `Envelope` remains the amplitude ADSR descriptor and both current initializers remain source compatible. `EnvelopeCurve` is `.linear` or `.exponential(exponent: Double)` with finite exponent greater than zero. `EnvelopeReleaseAnchor` is `.gateEnd` or `.eventEnd`. Additive Envelope initializers accept attack, decay and release curves plus a release anchor, defaulting all curves to linear and the anchor to gateEnd; existing values therefore keep their prior metadata. For a segment from `a` to `b`, normalized local time `t` uses `a + (b - a) * pow(t, exponent)`, with linear equivalent to exponent one. Attack runs 0 to 1, decay 1 to sustainLevel, sustain holds, and release starts at the selected anchor from the contour's actual value at that instant and reaches zero over releaseSeconds. Zero-length segments take their ending value without division.

`pitchEnvelope(_ envelope: Envelope, depth: Semitones)` and `filterEnvelope(_ envelope: Envelope, depth: Semitones)` replace the corresponding optional source modulation descriptor; their signed finite depth multiplies the normalized ADSR contour. Pitch adds that value in semitones. Filter modulation multiplies cutoff by `pow(2, depth * contour / 12)`, so zero depth is neutral and negative depth lowers cutoff. The P02.4 event envelope overrides only amplitude Envelope; source amplitude envelope is its fallback. Pitch/filter modulation each owns its supplied Envelope and does not reuse the amplitude event override. Outer declarations replace the same descriptor, and all metadata remains immutable.

`SourceFilter` retains its P02.4 kind/Q/slope shape. P03 permits `.lowPass`, `.highPass` and `.bandPass`, rejects `.notch`, requires finite resonance Q in `0.1...32`, and keeps `FilterSlope.twelve` and `.twentyFour`. `lowPass`, `highPass` and `bandPass` each have overloads accepting a fixed `Frequency` or a `CutoffPattern`, with `cycle: MusicalTime = .whole`, `resonanceQ: Double = 0.7071067811865476` and `slope: FilterSlope = .twelve`; a fixed value writes one cutoff to every current event and records an ordered `_LiveEventProgram` event operation so later recurring occurrences receive the same cutoff. It adds no independent period and does not remove periods from earlier pattern samplers. Every event under a source filter must have finite positive cutoff below the renderer sample-rate Nyquist limit after filter-envelope modulation. Invalid kind, Q, base cutoff or reachable modulated endpoint is a typed failure; no value is clamped. Existing `AudioEffect.filter` remains a post-mix render node owned by P04 and is not reinterpreted as this per-voice filter.

The additive public surface is fixed as follows; the existing four-argument Envelope calls remain valid because the new arguments default as shown.

```swift
public enum EnvelopeCurve { case linear; case exponential(exponent: Double) }
public enum EnvelopeReleaseAnchor { case gateEnd; case eventEnd }
public struct EnvelopeModulation {
    public let envelope: Envelope
    public let depth: Semitones
}

public init(
    attackSeconds: Double, decaySeconds: Double, sustainLevel: Double, releaseSeconds: Double,
    attackCurve: EnvelopeCurve = .linear, decayCurve: EnvelopeCurve = .linear,
    releaseCurve: EnvelopeCurve = .linear, releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
) throws
public init(
    attack: Duration, decay: Duration, sustainLevel: Double, release: Duration,
    attackCurve: EnvelopeCurve = .linear, decayCurve: EnvelopeCurve = .linear,
    releaseCurve: EnvelopeCurve = .linear, releaseAnchor: EnvelopeReleaseAnchor = .gateEnd
) throws

public func pitchEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound
public func filterEnvelope(_ envelope: Envelope, depth: Semitones) -> ModifiedSound
public func lowPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                    slope: FilterSlope = .twelve) -> ModifiedSound
public func highPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func bandPass(_ cutoff: Frequency, resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func highPass(_ cutoff: CutoffPattern, cycle: MusicalTime = .whole,
                     resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
public func bandPass(_ cutoff: CutoffPattern, cycle: MusicalTime = .whole,
                     resonanceQ: Double = 0.7071067811865476,
                     slope: FilterSlope = .twelve) -> ModifiedSound
```

```text
oscillator/sample frame
  -> sample traversal or pitch + pitch envelope
  -> per-voice source filter + filter envelope
  -> amplitude ADSR -> velocity -> event gain/pan
  -> source mix -> existing ordered render nodes
```

`Sample(_ name:)` and `SourceKind.sample(String)` keep their named procedural behavior. P03.3 adds `Sample(file:rootPitch:)` and `Sample(bank:)` as descriptor-only sources. `SampleAsset(key:fileURL:rootPitch:)` requires an absolute file URL and a key that the existing mini-pattern parser accepts by itself as exactly one non-rest leaf with the identical token text; whitespace, delimiters, operators, empty text and `~` are therefore rejected at the asset index rather than creating an unreachable bank entry. `rootPitch` defaults to `.middleC` and declares the pitch heard when decoded traversal rate is one under A4=440 equal temperament. The direct-file initializer has the same default. `SampleBank(_:)` requires an ordered nonempty array of `SampleAsset`, rejects duplicate keys, and never enumerates a directory. A bank source seeds its event with the first explicitly ordered asset key. `SampleSelectionPattern` is `ExpressibleByStringLiteral`, uses the existing bounded mini-pattern grammar and transforms, and permits bank keys but not rests; malformed syntax remains deferred for literals.

The compiler gives file/bank seed events pitch `.middleC`; a direct file event keeps `CompiledSoundEvent.sampleKey` nil and a bank seed stores its first key. Later notes, transpose and pitch patterns retain their existing effective-MIDI validation. `.sampleSelection(_ pattern: SampleSelectionPattern, cycle: MusicalTime = .whole)` samples the selected key at each current event onset, preserves rhythm/note provenance, and never changes event onset, duration, pitch, label or source identity. It requires a positive cycle and every affected source to be a bank containing every realized key; direct files, procedural samples, synthesizers, unknown keys, rests, empty realization, parser/count/period overflow and invalid UTF-8 locations fail with the declared typed error.

Modifier order follows the existing parameter-pattern contract. Before a rhythm/note generator, sample selection resolves only the current finite seed and contributes no future clock. After a generator it is an ordered `_LiveEventProgram` event sampler, contributes its complete transformed period to the checked common window and resolves every generated onset before periodic values are copied. Thus live variation is written `Sample(bank: bank).rhythm(...).sampleSelection(...)`; the API does not hide a pre-generator sampler in the constructor. A later selection replaces each event's earlier key value while earlier declared sampler periods remain in the LCM. `Sound.repeated` closes it with the existing template rule. Renderer and Playback never parse or advance the pattern.

Canonical live evaluation extends `_SoundCompilationContext.applyEvents` with read-only `CompiledSource` lookup. It uses existing source IDs to validate the event's bank and key and mutates only event copies; it does not allocate, replace or renumber sources, tracks or render nodes. `_LiveEventProgram.emit` receives the same immutable compiled-source snapshot that the initial compiler pass produced, so initial and future-onset validation share one bank authority.

The additive public surface is `Sample(file url: URL, rootPitch: Pitch = .middleC) throws`, `Sample(bank: SampleBank)`, `SampleAsset(key: String, fileURL: URL, rootPitch: Pitch = .middleC) throws`, `SampleBank(_ assets: [SampleAsset]) throws`, `sampleSelection(_:cycle:)`, `sampleRegion(_:)`, `sampleReversed()` and `samplePlaybackRate(_:) throws`. The rate is finite and strictly positive; one is neutral. Region is applied first, reversal changes traversal direction inside that region, and rate multiplies pitch traversal without changing musical event onset, gate, duration or compiled extent. An outer declaration replaces the same region, direction or rate setting. These settings apply only to file/bank descriptors as specified; applying them to a procedural named sample or synthesizer is a typed compilation failure. Pitch-preserving stretch remains P06.

The immutable compiled representation adds `SourceKind.fileSample(fileURL:rootPitch:)`, `SourceKind.sampleBank(SampleBank)`, optional `CompiledSoundEvent.sampleKey`, and `CompiledSource.sampleReversed` plus `samplePlaybackRate` whose defaults are false and one. `SampleDescriptorError` owns `invalidFileURL`, `emptyBank`, `invalidKey(index:)`, `duplicateKey(_:)` and `invalidPlaybackRate(_:)`. `SampleSelectionPatternError` owns parser/value failures with UTF-8 offsets; bank-dependent absence is `SoundCompilationError.unknownSampleKey(key:utf8Offset:)`, and applying traversal to an incompatible source is `SoundCompilationError.unsupportedSourceSetting`. Literal construction never converts one of these failures into an empty/default descriptor.

P03.3 file and bank samples are pitched through their explicit asset root. The renderer combines the selected asset's root, event pitch/offset, optional source tuning and pitch envelope with `samplePlaybackRate`; no filename or PCM analysis guesses pitch. Procedural built-ins have no decoded asset/root and retain the P03.2 typed rejection for those pitch settings. They keep their synthesized waveform and do not pass through the file loader. SwiftMusic owns descriptor/key/pattern/settings validation and immutable metadata only; it never opens a URL or decodes audio.

The native decode, cache, traversal and error contract is owned by the renderer design. Failure retains the previously adopted loop. Built-in kick/snare/closedHat generation remains available only for their existing names and is never a fallback for a failed file or bank reference.

`VoicePolicy` is an optional immutable source setting: `.monophonic` is exactly a one-voice oldest-stealing policy, while `.polyphonic(limit: Int, stealing: VoiceStealing)` requires `1...SoundCompiler.Limits.maximumEvents`. `VoiceStealing` is `.oldest` or `.quietest`. `voicePolicy(_:)` replaces the policy on every source in its subtree; nil metadata preserves the current render-all-overlaps path byte for byte. `chokeGroup(_ name: String)` replaces an optional nonblank normalized group name and may intentionally join different sources. Applying either modifier to an empty subtree still validates its value.

Compiler output adds optional `CompiledSource.voicePolicy` and `chokeGroup`; neither changes, removes, copies or retimes `CompiledSoundEvent`, source/track identity, render nodes, rhythm/note provenance or the live recurrence period. Modifier order only replaces source policy metadata. Invalid limits/names are typed `SoundParameterError` failures. Public types are `Sendable`, `Equatable` and `Hashable`, and the additive signatures are `voicePolicy(_ policy: VoicePolicy)` and `chokeGroup(_ name: String) throws`.

At each event onset the native scheduler first terminates every older active voice in the same choke group, then applies the incoming source's voice limit. Oldest chooses the smallest true onset and then compiled event order. Quietest compares the active voice's actual instantaneous stereo magnitude immediately before the incoming onset after oscillator/sample traversal, filter, amplitude envelope, velocity, event gain and pan but before source mixing; it does not substitute velocity, age or envelope level as a proxy. Equal finite magnitudes use oldest then compiled order. Simultaneous events are admitted in compiled event order, so a later same-frame choke or limit decision may terminate an earlier one deterministically. Release and seamless-wrap portions remain active until their true audible asset/envelope horizon; a terminated voice never resumes in the next cycle.

Allocation changes PCM ownership only. The immutable compiled event list and its source anchor, pattern text and step index remain complete even when a voice is suppressed or terminated, so clients retain the exact declaration provenance. P03.4 does not reinterpret selection patterns, change musical extent, add per-note public handles or promise editor visualization of allocation decisions.

## Ordered Mix and Effect Performance

P04 preserves the existing distinction between event `gain`/`pan` values and ordered subtree render nodes. `GainPattern` and `PanPattern` stay per-event before source mixing. Existing `.gain(Double)`, `.pan(Double)` and `.muted()` remain graph operations at their declaration position. Chained effects remain dependency ordered and a multi-source subtree is mixed once before its enclosing effect. SwiftMusic validates immutable descriptors and graph topology but performs no DSP or live parameter mutation.

P04.1 retains all existing `AudioEffect` cases and adds `case saturation(drive: Double)`. EQ frequency and Q are finite positive and gain dB finite; saturation and distortion drive are finite nonnegative; delay time is positive, feedback finite in `0..<1` and wet finite in `0...1`; reverb roomSize and wet are finite in `0...1`. Zero saturation/distortion drive and zero wet are neutral. Existing post-mix filter, compressor and chorus descriptors remain source compatible but are still explicit renderer-unsupported cases until their owning later sprint. Repeating EQ nodes is the public multi-band composition mechanism; P04 adds no separate EQ collection or mutable effect identity.

P04.3 makes a Track an explicit ordered mix boundary without changing event timing. `trackLevel(_ value: Double)`, `trackPan(_ value: Double?)`, `trackMuted(_ value: Bool = true)` and `trackSolo(_ value: Bool = true)` return a copied Track descriptor; defaults are level one, nil pan, false mute and false solo. Level is finite nonnegative. Optional pan is finite in `-1...1`, where nil is byte-preserving bypass and explicit zero uses the established equal-power law. Validation remains compiler-owned because these copy operations are nonthrowing. `CompiledTrack` carries `level`, `pan`, `isMuted`, `isSoloed` and optional dependency-ordered `renderNodeID`. After visiting and mixing all nonempty main-signal content inside a Track, including nested Track nodes, the compiler appends `CompiledRenderNode.track(input:trackID:)`, records that node ID and returns it before any modifier declared outside the Track. An empty Track preserves its metadata with nil `renderNodeID` and allocates no render node. For compatibility, output-routed roots inside a default Track remain transparent and are preserved beside its wrapped main-signal root; a Track with any nondefault level, pan, mute or solo setting and an output-routed root fails with the existing processing-order error instead of silently bypassing its setting. Existing generic gain/pan/mute declarations retain their exact graph positions.

If any Track is soloed, the renderer derives two sets from the immutable `CompiledTrack` hierarchy before rendering node buffers. The source-audible set is every soloed Track and its descendants; only events directly owned by those tracks may render, and untracked or ancestor-owned direct sources are silent. The transit-enabled set adds ancestors needed to carry those already-filtered descendant signals through enclosing track nodes. A transit ancestor does not make its own directly owned source audible. Unrelated track nodes are silent. Explicit mute always wins at its track node, including on an ancestor of a soloed Track, and therefore blocks that complete subtree. A transit-enabled track node still applies its declared child signal, level and optional pan before its mute/solo gate. Nested `parentID`, innermost event `trackID`, source identity, event/provenance arrays and live-event recurrence remain unchanged. Nil/default track settings preserve PCM exactly; the new node and optional `renderNodeID` are the stable authorities later meters and live track controls may address.

Compiler verification uses Swift Testing to prove every P04.1 success/failure and exact effect order, unchanged existing cases, unsupported-case preservation, zero-neutral descriptors, track node placement for single/mixed/nested content, empty and default routed-Track compatibility, typed rejection of nondefault settings after routing, level/pan/mute/solo precedence, solo source ownership versus ancestor transit, processing outside Track order, unchanged events/provenance and existing graph/node/depth bounds.

## Continuous Automation

P05.1 adds one shared signal vocabulary because LFO, steps and curves have identical normalized clock semantics, while application remains domain-specific. `AutomationSignal` is `lfo(LFO)`, `steps(StepAutomation)` or `curve(AutomationCurve)`. `LFOWaveform` is `sine`, `triangle`, `sawUp`, `sawDown` or `square`; `ModulationRate` is `hertz(Frequency)` or `synchronized(period: MusicalTime)`. `LFO.init(waveform:rate:phase:)` throws unless phase is finite in `0..<1` and the rate/period is positive. Every signal evaluates to finite `0...1`: sine is `(sin(2πp)+1)/2`, sawUp is `p`, sawDown is `1-p`, square is zero before half phase and one afterward, and triangle linearly visits zero, one and zero over a cycle.

`StepAutomation.init(values:cycle:)` throws unless it has 1...1,024 finite values in `0...1` and a positive cycle; values divide the cycle equally and hold until the next step. `AutomationPoint` has `position: MusicalTime`, `value: Double`, and `interpolationToNext: AutomationInterpolation`, where interpolation is `hold`, `linear` or `smoothstep`. `AutomationCurve.init(points:cycle:)` requires 1...1,024 points, a positive cycle, a first point at zero, strictly increasing positions below the cycle and normalized finite values. The final segment wraps to the first point at the cycle boundary using the last point's interpolation, so the curve has one defined cyclic value at every phase. `smoothstep` uses `t*t*(3-2*t)`. These are typed descriptors, not mini-notation or a public generic parameter-pattern facade.

Application types retain target validation and units: `GainAutomation.init(_:from:to:)` accepts finite nonnegative endpoints; `PanAutomation` accepts finite endpoints in `-1...1`; `PitchAutomation` accepts `Semitones`; and `CutoffAutomation` accepts `Frequency`. Endpoints may descend, and mapping is `from + normalized * (to - from)`. Sound overloads are `gain(_ automation: GainAutomation)`, `pan(_ automation: PanAutomation)`, `transpose(_ automation: PitchAutomation)`, and `lowPass/highPass/bandPass(_ automation: CutoffAutomation, resonanceQ:slope:)`. Existing scalar and domain-pattern overloads remain source-compatible. Gain/pan automation becomes dependency-ordered `CompiledRenderNode.gainAutomation(input:automation:)` / `panAutomation(input:automation:)`, preserving its declaration position. `CompiledSource.pitchAutomation: PitchAutomation?` and `cutoffAutomation: CutoffAutomation?` carry source automation to clients. Pitch automation is additive to the event's compiled pitch and onset-sampled pitch offset; the last continuous pitch automation declared for a source wins. A static, patterned or automated cutoff is one source-filter setting, so the outermost such declaration wins. Every reachable pitch endpoint must remain MIDI 0...127; cutoff endpoints must remain below the renderer Nyquist value. Unpitched procedural samples and white noise retain their explicit pitch-capability failures.

Onset patterns remain sampled by `SoundCompiler` and are never relabeled continuous. Continuous descriptors are retained unsampled in compiled sources/render nodes, and LoopRenderer evaluates them for every output frame using transport beat or elapsed seconds. A synchronized period contributes to live-loop common-period analysis and must divide the bounded compiled window by exact reduced `MusicalTime` rational remainder; it is never admitted or rejected through a Double quotient. Sound event-time modifiers such as `.fast` and `.slow` transform event recurrence only; they do not transform a retained continuous signal clock, regardless of whether the automation modifier appears inside or outside them. After event-program transformation and outermost source-setting replacement are complete, the compiler scans the final retained source automations and gain/pan automation nodes and combines each synchronized period with the transformed event period to choose the bounded common live window. Only an explicit rate/period in the automation descriptor changes its clock. An Hz LFO is BPM-independent; seamless rendering requires `frequency * physicalWindowSeconds`, where `physicalWindowSeconds` is the renderer's integer `frameCount / sampleRate`, to be a finite integral cycle count under the declared Double values. Otherwise rendering fails rather than resetting phase at the seam. Finite rendering accepts the same Hz signal through its owned horizon. Automation descriptor/point counts participate in existing compiler node/depth and 1,024-element bounds, with checked timing arithmetic before allocation. P05.1 adds no editor control identity or parameter provenance.

Code declaration order remains authoritative. Event gain/pan patterns keep their existing pre-source onset values; continuous gain/pan nodes then process the subtree at their graph position. Pitch automation adds to the already compiled event pitch/offset, while cutoff replacement follows the outermost source modifier rule above. P05.1 renders these four source/subtree automations into immutable PreparedLoop PCM while retaining every signal, mapping and target on `CompiledSound` sources/render nodes; PCM is not the sole semantic record. Failed/stale evaluation preserves that adopted automation and PCM. P05.1 itself exposes no callable live-control placeholder. The Playback design solely owns later live precedence and the retained-graph rerender/native-control path, and P05.7 must prove that path before an address is advertised as live.

Swift Testing proves all constructors and exact waveform/step/curve boundary values; descending mappings; declaration order against existing onset gain/pan/pitch/cutoff patterns; compiler node/source storage and final-descriptor synchronized-period contribution independent of surrounding event fast/slow order; effective-pitch, Nyquist, nonfinite, element and arithmetic failures; sample-accurate measured gain, stereo pan, oscillator pitch and RBJ cutoff movement; finite Hz behavior; seamless synchronized/Hz continuity at a non-frame-aligned 137 BPM window, physical-frame integral-Hz acceptance and nonintegral-Hz rejection; unchanged nil-automation PCM/events/provenance; and one compiled automated loop through native playback.

## Named Bus Routing

P05.2 preserves `Sound.send(to:level:)` as a declaration-position dry-preserving send and `output(_:)` as a terminal external sink. It adds `TrackSendPlacement.preFader` and `.postFader`, plus `Track.send(to:level:placement:) -> Track`; pre-fader taps the Track content before its level/equal-power pan, post-fader taps after them. Both placements obey the Track's solo eligibility and mute, and any muted ancestor suppresses the contribution, so pre-fader never bypasses the established complete-subtree mute invariant. Existing declaration-position Sound sends keep their graph position and do not acquire Track-fader semantics. Send level remains finite nonnegative and zero is an exact no-contribution branch.

`BusReturn(_ name: String)` is an eventless Sound primitive for one internal named-bus sum. It may be declared before or after senders and may receive ordinary effects/gain/pan/routing modifiers. A bus with a `BusReturn` requires exactly one return and at least one send; duplicate returns, a return without sends, invalid names and bound failures are typed compilation errors. For source compatibility, an existing declaration-position send without a BusReturn still compiles to its unchanged send node and represents an unresolved external contribution; MusicPlaygournd rejects that capability explicitly before rendering rather than discarding it silently. Internal bus names and external `output` names are separate namespaces. The native editor backend accepts unrouted roots and `output("main")` as its stereo main result; other external output names remain explicit capability failures until multi-output/stem ownership in P06.

`CompiledRenderNode.send(input:bus:level:)` remains the declaration-position identity/tap node. P05.2 adds `trackSend(input:bus:level:trackID:placement:)` and `busReturn(bus:inputs:)`; the return inputs identify contributing send-node IDs in stable declaration order. After the ordinary one-pass body visit, the compiler resolves bus names, adds return dependencies, performs a stable topological sort over every node kind, and remaps node inputs, roots and `CompiledTrack.renderNodeID` once. A return may feed another send, but any self or cross-bus cycle is rejected before CompiledSound is returned. Successful `renderNodes` remains dependency ordered and a node is evaluated once even when its signal feeds dry and bus consumers. Event timing, source/track identity, live recurrence and provenance remain unchanged.

`SoundCompiler.Limits.maximumBuses` is a source-compatible defaulted initializer field; MusicPlaygournd sets it to 32. Sends continue to consume the existing render-node limit. Compiler resolution uses checked node/edge counts and no recursive unbounded traversal. LoopRenderer performs a liveness pass before PCM allocation, retains each full stereo node buffer until its final dry/send/return consumer, and rejects a graph requiring more than 32 simultaneously live buffers. This ceiling is derived from the existing maximum 32 prepared source rows rather than an unbounded per-node cache. Buffer ownership and bus accumulation stay off the audio callback; final AudioTransport still owns one interleaved PreparedLoop.

Compiler Swift Testing proves source compatibility for existing send/output graphs, forward-declared returns, stable remapping across effects/Track nodes/P05.1 automation, pre/post-fader placement, duplicate/empty returns, legacy unmatched-send graph identity plus renderer rejection, maximum buses/nodes/edges and concrete self/cross cycles. Renderer tests prove one evaluation per shared node, exact dry preservation, multiple-send summation order, zero send, Track level/pan pre/post difference, solo source ownership, muted Track and muted-ancestor suppression, bus effects, main output selection, typed non-main output failure, 32-live-buffer admission/rejection, finite/seamless PCM and unchanged events/provenance. One evaluated named-bus session reaches nonzero native playback and a routing failure retains the previous revision.

Compiler tests own initializer/domain validation, inner-to-outer replacement, event-onset pattern selection, empty-subtree failure, capability errors, deterministic bank keys, voice policy and choke metadata, and unchanged legacy descriptors. Native tests own oscillator frequency, exact ADSR segment boundaries and release horizon, pitch/filter modulation, 12/24 dB filter response, resonance stability, real temporary-file decode, stereo preservation, selection/region/reverse/rate traversal, typed I/O failures and limits, deterministic stealing/choke output, nil-policy PCM compatibility, and nonzero hardware playback of a prepared result. All new tests use Swift Testing.
