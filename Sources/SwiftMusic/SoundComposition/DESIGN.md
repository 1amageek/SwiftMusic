# SoundComposition

## Purpose and Scope

SoundComposition owns the path from declarative `Sound` through six modifier categories to immutable beat events and render-plan descriptors. Its parent is the [SwiftMusic module](../DESIGN.md). It has no children.

| Category | Supported operations |
|---|---|
| Rhythm | `rhythm(_:cycle:)`, `offset(_:)`, `repeated(_:)`, `fast(_:)`, `slow(_:)` |
| Pitch and harmony | `notes(_:)`, `transpose(_:)`, `chord(_:)` |
| Expression | `dynamic(_:)`, `velocity(_:)`, `gate(_:)`, `staccato()` |
| Source settings | `tuning(_:)`, `envelope(_:)`, `sampleRegion(_:)`, `unison(_:)` |
| Audio effects | `effect(_:)` with EQ, filter, compressor, distortion, delay, reverb, chorus |
| Mix and routing | `gain(_:)`, `pan(_:)`, `muted()`, `send(to:level:)`, `output(_:)` |

Swing, quantization, scales, voicing, arpeggiation, accent, legato, techniques, pitch envelopes, automation, and broader pattern syntax are deferred without placeholder APIs.

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

`RhythmPattern` parses one or more ASCII-whitespace-separated `x` and `~` tokens. Its throwing initializer reports empty input or the first invalid token and zero-based token index; steps are immutable.

`rhythm(pattern, cycle)` requires nonzero cycle and divides it equally by step count. Each hit clones each child event, adds the step onset to its start, and sets duration to one step; rests emit nothing. Extent is at least the full cycle, preserving trailing rests. Nested modifiers apply inner-to-outer. `offset` adds to starts and extent. `repeated(count)` requires positive `Int`, copies the child sequentially at multiples of child extent, and multiplies extent. `fast` and `slow` require positive `UInt64` and divide or multiply starts, durations, and extent. Expansion and arithmetic are bounded before allocation.

### Pitch, harmony, and expression

`notes(_:)` requires a nonempty `[Pitch]` and assigns pitches cyclically in current event order. `transpose(_:)` requires pitched events and checked MIDI 0...127 results. `chord(_:)` requires pitched events and expands fixed intervals in order: `.major` = 0,4,7; `.minor` = 0,3,7; `.power` = 0,7; `.dominantSeventh` = 0,4,7,10. Expanded notes retain source, track, time, and expression.

`CompiledSoundEvent` exposes source ID, optional track ID, start, rhythmic duration, optional pitch, MIDI velocity, and gate ratio. Defaults are velocity 80 and gate 1. `Dynamic` maps `pp`, `p`, `mp`, `mf`, `f`, `ff` to documented fixed velocities. `dynamic` and `velocity` replace velocity; velocity requires 1...127. `gate` replaces gate and requires finite positive input. `staccato` multiplies current gate by 0.5. Expression never changes beat duration or extent.

### Source settings

`Tuning(referencePitch:frequencyHz:)`, `Envelope(attackSeconds:decaySeconds:sustainLevel:releaseSeconds:)`, `SampleRegion(startFraction:endFraction:)`, and `Unison(voices:detuneCents:)` have throwing initializers. Frequencies are finite positive; time and detune are finite nonnegative; normalized fields are 0...1; region start is less than end; unison is 1...16 voices.

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
| Pitch/harmony | Notes cycle, transpose MIDI bounds, all chord intervals/order, unpitched errors |
| Expression | Dynamic, velocity/gate validation, stacked staccato fields with unchanged extent |
| Sources | Both descriptors, common settings, region/unison capability success and failure |
| Effects/mix | Each effect success/failure; source-chain and mix-effect order; gain, pan, mute, send, output, roots, subtree scope; routed and unrouted siblings remain separate; every processing-after-output form fails |
| Track | Unmodified wrapper preserves events/nodes; nested and empty metadata remains |
| Bounds/determinism | Depth, events, tracks, sources, nodes fail without output; IDs and event order repeat |
| Foundation | Rational operations remain checked; one compiled sound maps through distinct tempi unchanged |

The focused suite runs after stable integration. Deferred operations require explicit semantics, errors, bounds, and output evidence before implementation.
