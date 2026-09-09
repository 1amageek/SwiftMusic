# SwiftMusic

Product direction and the intended live-editing experience are owned by [PHILOSOPHY.md](PHILOSOPHY.md). This document describes the current implementation boundary; its exclusions are not permanent product limitations.

## Purpose and Scope

SwiftMusic provides declaration-local MainActor state through the [SoundComposition State contract](Sources/SwiftMusic/SoundComposition/DESIGN.md#declaration-local-state), declares immutable `Sound` trees, prepares them as deterministic beat-domain events plus an ordered render plan, and provides value-state transitions for adopting prepared updates at a host-selected musical boundary. This file is both system and package design because the roots are the same. The package contains one module, [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md).

This task provides one working set in each of six modifier categories: rhythm, pitch and harmony, expression, source settings, audio effects, and mix and routing. Render-plan data describes audio work; this package does not synthesize PCM or prove that an effect was heard.

Playback, an audio backend, editor UI, persistence, MIDI I/O, meter, tempo automation, broad pattern syntax, parameter automation, and notation import/export are outside this package. The package does not create a playback clock or choose when a musical boundary occurs. It preserves compiler call-site provenance for rhythm and note-pattern source rows; clients own layout and edit mapping.

## Responsibilities and Boundaries

SwiftMusic owns `Music`, composable `Sound`, `SoundBuilder`, source declarations, modifier values, exact musical time, bounded preparation, observable render-plan order, separate tempo conversion, and state rules that preserve the last adopted sound across invalid or stale updates. Clients own audio rendering, scheduling, isolation of each mutable `LiveMusicState`, musical-boundary detection, revision allocation, and editor presentation.

The unreleased `Score` API is replaced. `Score`, `ScoreBuilder`, `CompiledScore`, `ScoreCompiler`, `Note`, and `Rest` are removed instead of retained as aliases; the replacement occurred before the 0.1.0 preview tag. MusicPlaygournd is a separate [host repository](https://github.com/1amageek/MusicPlaygournd), pinned to the public SwiftMusic release. SwiftMusic 0.3.0 adds declaration-local State; audio, editor and release lifecycles remain host responsibilities.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md) | child | public SwiftMusic module | Defines module composition and export boundary | Do not duplicate event or render-plan models in clients |

## Architecture

```text
MainActor Music.body: some Sound
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

edit revision -> LiveMusicUpdate.prepare -> prepared / failed
       |                                      |
       `-> LiveMusicState.beginUpdate --------'
                         |
             host boundary callback
                         v
                 adopted current sound
```

The package has no third-party dependency, clock access, or I/O. Optional performance-model resolution and Observation state are MainActor-owned; compiled Sound values remain independent of that state.

## Contracts and Invariants

- `Music` is the MainActor work-level entry; `Sound` is every nonisolated composable declaration, not PCM storage.
- A performance model is explicitly injected before body evaluation. It is never default-constructed or inferred from arbitrary state, and a missing provider is a typed compilation failure.
- `SoundBuilder` siblings start at the same musical origin. Parallel composition remains the default.
- Modifier order is Swift call-chain order from source outward and is observable in transformed events or the render plan.
- Rhythm, pitch, and expression modifiers transform compiled events in their subtree.
- Source settings alter matching leaf-source descriptors in their subtree; unsupported source capabilities fail compilation.
- Effect and mix modifiers append post-mix nodes around their subtree and preserve chain order; `output` is a terminal routed sink and is never mixed back into or consumed by later processing.
- `Track` is optional metadata and changes neither event time nor the render plan when unmodified.
- Beat-domain output is independent of `Tempo`; one compiled sound maps at different BPM values.
- Arithmetic, expansion, graph, and scalar failures are typed and never return a partial result.
- `RhythmPattern` and `NotePattern` string literals retain invalid input as a diagnostic candidate; they never trap or substitute an empty pattern.
- Rhythm and note-pattern modifiers capture compiler file, line, and column at their call site. The outermost such modifier supplies each affected source row's anchor; unrelated transforms preserve it.
- A newer edit revision invalidates any older pending candidate immediately. Only the matching latest preparation completion may become pending, and only `adoptPendingAtBoundary()` may replace the current sound.
- Failed, duplicate, and stale updates leave the current sound unchanged. A failed initial update leaves the state without a current sound.

## Failure, Concurrency, and Constraints

Preparation is synchronous, bounded by recursive depth, events, tracks, sources, render nodes and performance requirements, and deterministic for the MainActor-isolated model snapshot read by that body evaluation. Music bodies remain side-effect free even when they read injected state. Repetition, pattern expansion, rhythm hits, and chord expansion count against event limits before unbounded allocation. `LiveMusicState` is a mutable `Sendable` value with no internal shared storage; the host must isolate each instance. Sound declarations, updates, and compiled results are immutable `Sendable` values; injected Observable models have the separate ownership contract above.

This release promises native Swift value and compiler behavior only. It makes no DSP, audible-output, real-time, Embedded Swift, or WASM claim.

## Verification and Change Impact

Public tests execute custom `Music` and `Sound` bodies, builder control flow, literal grammar and diagnostics, parallel timing, all supported event transforms, source-setting capability failures, effect and mix order and scope, track transparency, resource bounds, exact time arithmetic, separate tempo mapping, and live update state transitions. Tests must show a valid current sound survives invalid and stale edits until a later valid candidate is explicitly adopted. README code must compile and run as an external client.

Changes to event semantics, modifier placement, source provenance, node order, IDs, bounds, or public names require review of the module and [`SoundComposition`](Sources/SwiftMusic/SoundComposition/DESIGN.md) designs.

The [SoundComposition nested-pattern contract](Sources/SwiftMusic/SoundComposition/DESIGN.md#nested-mini-notation-and-gain-patterns) extends rhythm and notes with exact bracket subdivisions and onset-sampled per-event gain. Its [domain parameter-pattern contract](Sources/SwiftMusic/SoundComposition/DESIGN.md#domain-parameter-patterns) preserves GainPattern, adds the separate PanPattern, and gives both deferred integer fast/slow phase transforms while sharing only internal parser/timing machinery. The [rational pattern-rate contract](Sources/SwiftMusic/SoundComposition/DESIGN.md#rational-pattern-rates) adds exact fractional speed without introducing a public generic parameter pattern. Existing scalar render-node behavior remains unchanged. The initial audible implementation target is the native macOS MusicPlaygournd backend; this increment makes no new WASM claim.
