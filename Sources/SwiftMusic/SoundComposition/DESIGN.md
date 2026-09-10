# SoundComposition

## Purpose and Scope

Composable Music and Sound declarations and structural builder containers. Children: Sources and Modifiers.

## Responsibilities and Boundaries

This directory owns the types listed below within the single SwiftMusic target. Directory moves introduce no new module or visibility boundary. Existing internal collaborators remain in the same module; audio rendering, devices and editor UI stay outside SwiftMusic.

`AnySound`, `ArraySound`, `BusReturn`, `ConditionalSound`, `EmptySound`, `ModifiedSound`, `Music`, `OptionalSound`, `Sound`, `SoundBuilder`, `SoundChildren`, `SoundGroup`, `SoundNode`, `SoundPrimitive`, `Track`, `TupleSound`.

## Related Designs

- Parent: [SwiftMusic](../DESIGN.md).
- Verification: [SwiftMusicTests](../../../Tests/SwiftMusicTests).
- Child: [Sources](Sources/DESIGN.md).
- Child: [Modifiers](Modifiers/DESIGN.md).
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

### Declaration and sources

```swift
public protocol Music: Sendable {
    associatedtype Body: Sound
    @MainActor
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

### Typed structural sounds

SoundBuilder preserves each expression's concrete Sound type. Empty blocks produce EmptySound; single expressions remain unchanged; sibling blocks produce TupleSound<(repeat each Content)> using Swift 6 parameter packs. TupleSound owns the typed tuple and a Sendable child visitor specialized by its initializer. It does not construct an existential child array. The visitor borrows the tuple while synchronously submitting children to the compiler; no reference escapes its scope.

ConditionalSound<TrueContent, FalseContent> stores only the selected enum case. Optional<Wrapped> conforms to Sound when Wrapped does; nil compiles as empty. ArraySound<Content> stores the homogeneous finite for-loop results. SoundGroup<Content> provides an explicit builder scope, and AnySound erases a single value only where explicitly requested or needed by buildLimitedAvailability. Each structural declaration exposes its children through the internal _SoundChildren contract; the compiler recognizes this before evaluating the terminal Never body. Child traversal preserves source order, parallel origins, typed failures, depth/event/source/node limits and captured live programs. Empty composites allocate no sources or tracks.

Track keeps its existing concrete public type and owns one existential content value, preserving the typed structure inside that value instead of flattening a SoundGroup array. ModifiedSound remains an existing type-erasure boundary. This increment does not make all modifier types generic, introduce identity reconciliation, cache by structural type, or promise allocation-free compilation.

This changes explicit builder result annotations: use some Sound for reusable bodies and generic Content: Sound builder parameters. SoundGroup is now generic and explicitly constructible. Existing source written with inferred Track closures and body: some Sound retains its syntax. Compiled event and render-plan APIs are unchanged; structural grouping may change equivalent mix-node topology and depth consumption, so clients must not assume exact compiler-generated node indices across source changes.

Verification belongs to TypedSoundBuilderTests and existing SoundComposition/live compiler tests: compile-time concrete result assertions accompany real selected-branch events, optional/empty behavior, finite loops, group modifier scope, track nesting, source anchors, typed invalid inputs, depth limits and live-loop compilation. The host consumer must compile against the changed library; no PCM backend behavior is claimed by these tests.
