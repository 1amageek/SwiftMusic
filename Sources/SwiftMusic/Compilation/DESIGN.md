# Compilation

## Purpose and Scope

Validation and deterministic preparation of declarations into events and render plans. No children.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`HarmonyCopies`, `HarmonyEventProcessing`, `LiveEventProgram`, `LiveLoopPolicy`, `LocatedSoundCompilationError`, `PerformanceCompilation`, `RhythmEventProcessing`, `SoundCompilationContext`, `SoundCompilationError`, `SoundCompiler`, `SoundFragment`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Related component: [SoundComposition](../SoundComposition/DESIGN.md); shared SwiftMusic types retain their existing access levels.
- Related component: [MusicalValues](../MusicalValues/DESIGN.md); shared SwiftMusic types retain their existing access levels.
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

### P07 source-located editor diagnostics

The gain, pan, pitch, cutoff, envelope and sample-selection pattern modifier overloads add defaulted `fileID: String = #fileID`, `line: Int = #line` and `column: Int = #column`, matching rhythm/note provenance without changing ordinary call syntax. Their internal modifier values retain that declaration anchor solely for error location; successful compilation continues to preserve the rhythm/note anchor and lexical step index as the audible row authority. `SoundCompiler.compileDetailed` follows the same compile path but throws `LocatedSoundCompilationError(underlying:anchor:utf8Offset:)` when a domain-pattern failure has a declaration anchor. Existing `compile` unwraps and throws the same existing `SoundCompilationError`, preserving its public failure behavior. Missing transform-derived offsets remain nil rather than fabricated.

Compiler tests prove each domain's exact UTF-8 token offset plus declaration anchor, Unicode before the literal, successful provenance unchanged and `compile` compatibility. MusicPlaygournd Evaluation owns wrapper-to-Session.swift range conversion and UI diagnostics.

## Pattern preparation lifetime

The compilation context owns one bounded value cache under the [Patterns reuse contract](../Patterns/DESIGN.md#compilation-scoped-parse-reuse). Finite modifier application, live period discovery and recursive emission share exclusive access to it. A temporary event-transform context borrows ownership using swap and returns it with defer, including on failure. Modifier order, source anchors, event limits and public compiler errors are unchanged. Each public compile constructs a fresh context and releases the cache when compilation returns; no mutable cache crosses Sendable or platform boundaries.
