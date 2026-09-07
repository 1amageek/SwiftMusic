# SwiftMusic

## Purpose and Scope

SwiftMusic declares immutable `Sound` trees and compiles them into deterministic beat-domain events plus an ordered render plan. This file is both system and package design because the roots are the same. The package contains one module, [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md).

This task provides one working set in each of six modifier categories: rhythm, pitch and harmony, expression, source settings, audio effects, and mix and routing. Render-plan data describes audio work; this package does not synthesize PCM or prove that an effect was heard.

Playback, an audio backend, editor UI, source-code instrumentation, persistence, MIDI I/O, meter, tempo automation, broad pattern syntax, parameter automation, and notation import/export are outside this task.

## Responsibilities and Boundaries

SwiftMusic owns `Music`, composable `Sound`, `SoundBuilder`, source declarations, modifier values, exact musical time, bounded compilation, observable render-plan order, and separate tempo conversion. Clients own audio rendering, scheduling, playback state, and editor presentation.

The unreleased `Score` API is replaced. `Score`, `ScoreBuilder`, `CompiledScore`, `ScoreCompiler`, `Note`, and `Rest` are removed instead of retained as aliases; there is no published compatibility contract or remote tag.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md) | child | public SwiftMusic module | Defines module composition and export boundary | Do not duplicate event or render-plan models in clients |

## Architecture

```text
Music.body: some Sound
          |
          v
 Sound tree + ordered modifiers
          |
          v
    SoundCompiler
       |       |
       v       v
 beat events  ordered render plan
       |
       v
 Tempo.seconds(for:)       audio backend and editor are clients
```

The package has no third-party dependency, global mutable state, task, clock access, or I/O.

## Contracts and Invariants

- `Music` is the work-level entry; `Sound` is every composable declaration, not PCM storage.
- `SoundBuilder` siblings start at the same musical origin. Parallel composition remains the default.
- Modifier order is Swift call-chain order from source outward and is observable in transformed events or the render plan.
- Rhythm, pitch, and expression modifiers transform compiled events in their subtree.
- Source settings alter matching leaf-source descriptors in their subtree; unsupported source capabilities fail compilation.
- Effect and mix modifiers append post-mix nodes around their subtree and preserve chain order; `output` is a terminal routed sink and is never mixed back into or consumed by later processing.
- `Track` is optional metadata and changes neither event time nor the render plan when unmodified.
- Beat-domain output is independent of `Tempo`; one compiled sound maps at different BPM values.
- Arithmetic, expansion, graph, and scalar failures are typed and never return a partial result.

## Failure, Concurrency, and Constraints

Compilation is synchronous, deterministic, side-effect free, and bounded by recursive depth, events, tracks, sources, and render nodes. Repetition, rhythm hits, and chord expansion count against event limits before unbounded allocation. Public values and results are immutable `Sendable` values.

This release promises native Swift value and compiler behavior only. It makes no DSP, audible-output, real-time, Embedded Swift, or WASM claim.

## Verification and Change Impact

Public tests execute custom `Music` and `Sound` bodies, builder control flow, parallel timing, all supported event transforms, source-setting capability failures, effect and mix order and scope, track transparency, resource bounds, exact time arithmetic, and separate tempo mapping. README code must compile and run as an external client.

Changes to event semantics, modifier placement, node order, IDs, bounds, or public names require review of the module and [`SoundComposition`](Sources/SwiftMusic/SoundComposition/DESIGN.md) designs.
