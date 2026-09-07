# SwiftMusic Module

## Purpose and Scope

This module exports one declarative sound and render-plan model. Its parent is the [package design](../../DESIGN.md); its only component is [`SoundComposition`](SoundComposition/DESIGN.md).

## Responsibilities and Boundaries

The module exports the component contract without an adapter layer or second representation. It owns neither PCM nor editor or playback state.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../../DESIGN.md`](../../DESIGN.md) | parent | package invariants | Defines outcome and client boundaries | Public changes affect the package contract |
| [`SoundComposition/DESIGN.md`](SoundComposition/DESIGN.md) | child | declaration, compilation, and render-plan contract | Owns all production types | Modifier semantics live only there |

## Architecture

```text
Music -> SoundBuilder -> SoundComposition -> SoundCompiler -> CompiledSound
```

Production source belongs to `SoundComposition/`.

## Contracts and Invariants

- The module exports `Music.body`, `Sound.body`, and one `SoundBuilder` path.
- Previous `Score` declarations and compiled types are absent after migration.
- Public values are immutable `Sendable` values.
- Tempo remains independent from declarations and compiled output.

## Failure, Concurrency, and Constraints

The module preserves typed component failures. It does not catch errors as success, run asynchronously, or introduce shared state.

## Verification and Change Impact

Tests import only `SwiftMusic`. A future audio or editor module consumes `CompiledSound` and its render plan rather than component internals.
