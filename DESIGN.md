# SwiftMusic

## Purpose and Scope

SwiftMusic is a Swift package for declaring immutable musical scores and compiling them into deterministic beat-domain events. This file is both the system and package design because the repository and package roots are the same directory.

The package contains one library module, [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md). Audio synthesis, playback, editor UI, source-code instrumentation, persistence, MIDI I/O, a textual rhythm language, effects, dynamics, meter, and notation import/export are outside this foundation.

## Responsibilities and Boundaries

SwiftMusic owns:

- the top-level `Music` declaration contract;
- the composable `Score` declaration contract and `ScoreBuilder`;
- immutable musical-time, note, rest, and named-track values;
- compilation of a declaration tree into bounded, deterministic beat-domain events;
- conversion of musical time to seconds using a separately supplied tempo.

Clients own audio scheduling, synthesis, playback state, editor presentation, and source-to-score correspondence. No package API reads a clock, starts a task, mutates global state, or performs I/O.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`Sources/SwiftMusic/DESIGN.md`](Sources/SwiftMusic/DESIGN.md) | child | `SwiftMusic` public module | Defines the module composition and exported contract | Package changes must preserve its platform-independent value semantics |

## Architecture

```text
Client Music declaration
        |
        v
SwiftMusic module
        |
        +-- ScoreComposition ----> CompiledScore (musical time)
                                      |
                                      +-- Tempo ----> seconds
        |
        +-- future client adapters: audio and editor (outside package)
```

Dependency direction is client -> public SwiftMusic values -> internal compiler. The foundation has no third-party dependencies.

## Contracts and Invariants

- A `Music` value supplies one score root and does not own tempo or playback state.
- A `Score` value is immutable and `Sendable`; its `body` composes lower-level scores.
- Sibling expressions emitted by `ScoreBuilder` begin at the same musical origin. Parallel composition is the default.
- `Track` is optional metadata and grouping. Adding or removing a `Track` wrapper does not shift event time.
- Compilation produces the same ordered result for the same score value and limits.
- Compiled event positions and durations remain in exact musical time. Applying a different `Tempo` never recompiles or mutates the score.
- Resource and arithmetic bounds fail explicitly; compilation never silently drops, truncates, or clamps an event.

## Failure, Concurrency, and Constraints

Compilation is synchronous, side-effect free, and safe to call concurrently with independent values. Public values contain no shared mutable state.

Default compilation limits are owned by `ScoreCompiler.Limits` and protect recursive traversal depth across every score node, event count, and track count. Clients may lower or raise them for their workload. Limit violations, zero note duration, invalid MIDI pitch, and musical-time overflow are typed errors. Invalid tempo input and non-finite second conversion are typed tempo errors.

The first release promises native Swift behavior only. It makes no Embedded Swift, WASM, real-time audio, or allocation-budget claim.

## Verification and Change Impact

The `SwiftMusicTests` target owns behavioral verification. Tests must execute external `Music` and custom `Score` bodies, builder branches and loops, parallel timing, optional and nested tracks, rests, deterministic ordering, typed failures, and two-tempo conversion of one compiled score. A build or protocol-conformance check alone is insufficient.

Changes to public declaration or event semantics require review of the module and component designs. Audio or editor work must consume `CompiledScore` as a boundary and define separate designs before entering this package.
