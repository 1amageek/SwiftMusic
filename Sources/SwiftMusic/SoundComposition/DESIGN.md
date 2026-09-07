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
