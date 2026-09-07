# SwiftMusic Module

## Purpose and Scope

This module exports one declarative sound and render-plan model, including optional compiler source provenance for pattern-generated rows. Its parent is the [package design](../../DESIGN.md); its components are [`SoundComposition`](SoundComposition/DESIGN.md) and [`LiveUpdates`](LiveUpdates/DESIGN.md).

## Responsibilities and Boundaries

The module exports the component contract without an adapter layer or second representation. It owns neither PCM nor editor or playback state.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../../DESIGN.md`](../../DESIGN.md) | parent | package invariants | Defines outcome and client boundaries | Public changes affect the package contract |
| [`SoundComposition/DESIGN.md`](SoundComposition/DESIGN.md) | child | declaration, compilation, and render-plan contract | Owns musical declarations and plans | Modifier semantics live only there |
| [`LiveUpdates/DESIGN.md`](LiveUpdates/DESIGN.md) | child | preparation and revision state | Preserves adopted plans across failed edits | The host supplies isolation and musical boundaries |

## Architecture

```text
Music -> SoundBuilder -> SoundComposition -> SoundCompiler -> CompiledSound
```

Composition source belongs to `SoundComposition/`; live update value-state source belongs to `LiveUpdates/`. LiveUpdates depends only on the public composition contract.

## Contracts and Invariants

- The module exports `Music.body`, `Sound.body`, and one `SoundBuilder` path.
- Previous `Score` declarations and compiled types are absent after migration.
- Declarations and prepared results are immutable `Sendable` values; `LiveMusicState` is a mutable value isolated by its host.
- Tempo remains independent from declarations and compiled output.
- `SoundSourceAnchor` is immutable value metadata captured by pattern-modifier default arguments. `CompiledSource.patternAnchor` is canonical, including all-rest patterns; events continue to join sources by `sourceID`.

## Failure, Concurrency, and Constraints

The module preserves typed component failures, including failed live preparation. It does not catch errors as success, run asynchronously, or introduce shared state.

## Verification and Change Impact

Tests import only `SwiftMusic`. A future audio or editor module consumes `CompiledSound` and its render plan rather than component internals.
