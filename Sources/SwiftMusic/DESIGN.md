# SwiftMusic Module

## Purpose and Scope

This module exports one declarative sound and render-plan model, including optional compiler source provenance for pattern-generated rows and MainActor-resolved performance-model declarations. Its parent is the [package design](../../DESIGN.md); its components are [`SoundComposition`](SoundComposition/DESIGN.md) and [`LiveUpdates`](LiveUpdates/DESIGN.md).

## Responsibilities and Boundaries

The module exports the component contract, including declaration-local State as owned by SoundComposition, without an adapter layer or second representation. It owns neither PCM nor editor or playback state.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../../DESIGN.md`](../../DESIGN.md) | parent | package invariants | Defines outcome and client boundaries | Public changes affect the package contract |
| [`SoundComposition/DESIGN.md`](SoundComposition/DESIGN.md) | child | declaration, compilation, and render-plan contract | Owns musical declarations and plans | Modifier semantics live only there |
| [`LiveUpdates/DESIGN.md`](LiveUpdates/DESIGN.md) | child | preparation and revision state | Preserves adopted plans across failed edits | The host supplies isolation and musical boundaries |

## Architecture

```text
MainActor Music.body -> SoundBuilder -> SoundComposition -> SoundCompiler -> CompiledSound
```

Composition source belongs to `SoundComposition/`; live update value-state source belongs to `LiveUpdates/`. LiveUpdates depends only on the public composition contract.

## Contracts and Invariants

- The module exports `Music.body`, `Sound.body`, and one `SoundBuilder` path.
- Previous `Score` declarations and compiled types are absent after migration.
- Music requirements and Sound/prepared results are `Sendable`; an explicitly resolved performance model and its Observation session are MainActor-owned reference state, while `LiveMusicState` remains a mutable value isolated by its host.
- Tempo remains independent from declarations and compiled output.
- `SoundSourceAnchor` is immutable value metadata captured by pattern-modifier default arguments. `CompiledSource.patternAnchor` is canonical, including all-rest patterns; events continue to join sources by `sourceID`.

## Failure, Concurrency, and Constraints

The module preserves typed component failures, including missing performance injection and failed live preparation. Performance Observation is MainActor-owned and only notifies its host; compilation still runs synchronously outside the audio callback and never catches errors as success.

## Verification and Change Impact

Tests import only `SwiftMusic`. A future audio or editor module consumes `CompiledSound` and its render plan rather than component internals.

Nested bracket subdivisions and per-event gain patterns are owned by [SoundComposition](SoundComposition/DESIGN.md#nested-mini-notation-and-gain-patterns). Clients render event gain before the existing ordered audio graph; scalar gain remains post-mix.

Typed declaration structure and builder source compatibility are owned by the [structural sound contract](SoundComposition/DESIGN.md#typed-structural-sounds). Compiled event and render-plan interfaces remain unchanged.
