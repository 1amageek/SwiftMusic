# ScoreComposition

## Purpose and Scope

ScoreComposition owns the smallest complete path from declarative Swift values to observable musical events. Its parent is the [SwiftMusic module](../DESIGN.md). It has no child components.

This foundation implements `Music`, `Score`, `ScoreBuilder`, `Track`, `Note`, `Rest`, exact `MusicalTime`, `Pitch`, `ScoreCompiler`, `CompiledScore`, track metadata, compiled note events, and `Tempo`. A textual rhythm parser and audio or editor features are deferred until this boundary has a real consumer.

## Responsibilities and Boundaries

The component owns:

- declaration composition and its default parallel semantics;
- expansion of client-defined `Score.body` values;
- package-owned terminal score values;
- exact, bounded musical-time arithmetic;
- stable event ordering and observable track nesting;
- tempo-based conversion from musical time to seconds.

It does not own sequential notation syntax, playback, synthesis, effects, automation, dynamics, meter, source locations, or UI state. Initial rhythm is expressed by typed `Note` and `Rest` values with explicit start offsets and durations.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`../DESIGN.md`](../DESIGN.md) | parent | module export boundary | Re-exports this component as `SwiftMusic` | Public types must remain coherent as one module |
| [`../../../DESIGN.md`](../../../DESIGN.md) | package ancestor | package invariants | Defines tempo separation and excluded adapters | Do not make platform or playback claims |
| [`../../../Tests/SwiftMusicTests`](../../../Tests/SwiftMusicTests) | verification owner | public `SwiftMusic` API | Proves declaration-to-event behavior | Tests must observe events, tracks, errors, and seconds |

## Architecture

```text
struct Song: Music                 client-defined Fragment: Score
  score: some Score                  body: some Score
          |                                  |
          +------------+---------------------+
                       v
                  ScoreBuilder
             (parallel composition)
                       |
          +------------+--------------+
          |            |              |
       Track         Note           Rest
      metadata      terminal       terminal
          \            |              /
           +-----------+-------------+
                       v
                 ScoreCompiler
                       |
             +---------+---------+
             |                   |
       CompiledTrack       CompiledNoteEvent
             +---------+---------+
                       v
                 CompiledScore
                       |
                Tempo.seconds(for:)
```

Package-owned terminal types are detected through an internal protocol before the compiler asks for `body`. External conformers cannot become terminals; the compiler expands their public `body`. `Never` conforms to `Score` so terminal types can declare `Body == Never`; its uninhabited body is never evaluated on a successful compilation path.

## Contracts and Invariants

### Declaration contracts

```swift
public protocol Music: Sendable {
    associatedtype ScoreContent: Score

    @ScoreBuilder var score: ScoreContent { get }
}

public protocol Score: Sendable {
    associatedtype Body: Score

    @ScoreBuilder var body: Body { get }
}
```

`Music` is the work-level entry point. Its only semantic property is `score`; tempo is supplied independently when musical time is mapped to real time. A client-defined `Score` is a reusable declaration whose body is recursively expanded.

`ScoreBuilder` supports zero or more sibling expressions, `if`, `if/else`, availability branches, and finite `for` loops. Each builder result is one immutable package-owned composition value. Siblings share origin zero; source order is used only as a deterministic tie-breaker and never implies sequential playback.

`Track(name) { ... }` applies a name and nesting boundary to its child composition without changing child timing. A score may contain events outside any track. Nested and empty tracks remain visible in `CompiledTrack` metadata. The compiler assigns snapshot-local track identifiers as zero-based pre-order ordinals; names do not participate in identity, and identifiers are not stable across score edits.

### Musical values

`MusicalTime` is a normalized non-negative rational count of quarter-note beats backed by `UInt64` numerator and denominator values. Zero is valid for positions and score extent; a note duration must be greater than zero. Public constants cover common whole, half, quarter, eighth, and sixteenth values, and a throwing initializer admits other representable rational values. Addition is exact when its checked `UInt64` intermediates and normalized result fit; it may report overflow even when an arbitrary-precision implementation could reduce the mathematical result back into two `UInt64` values. Comparison uses full-width products and does not overflow.

`Pitch` contains one MIDI note number (`UInt8`) as a transport-neutral first pitch representation. Its throwing initializer accepts only MIDI values 0...127 and reports a typed `PitchError.outOfRange` for 128...255. `Note` contains pitch, start offset, and duration. `Rest` contains a start offset and duration, emits no note event, and contributes its end to containing score extent. A zero-duration rest is valid and can mark an extent at its start position. Note velocity, dynamics, articulation, and tuning are deferred rather than encoded as placeholder fields.

### Compilation contracts

`ScoreCompiler` compiles either `Music` or `Score` into `CompiledScore`. It recursively expands external bodies and recognizes only package-owned composition and terminal types. Compilation result contains:

- note events with start, duration, pitch, and the innermost containing track identifier when present;
- a deterministic pre-order list of tracks with identifier, name, and optional parent identifier;
- total musical extent, equal to the maximum end of every note, rest, or child composition.

Events are ordered by start time, then declaration traversal order. Equal-time events are not reordered by pitch or track name. A parallel composition's extent is the maximum child extent. A track has its child's extent and does not offset it.

Compilation is total for valid finite declarations: package-owned terminal bodies are never evaluated; an external custom score is expanded until it reaches package-owned values or a configured bound. The traversal-depth bound applies to every recursive descent through custom bodies, package-owned groups, and tracks. It returns a typed `ScoreCompilationError` for zero note duration, arithmetic overflow, traversal-depth exhaustion, event-limit exhaustion, or track-limit exhaustion. It never returns a partial score.

### Tempo contract

`Tempo` contains a finite positive beats-per-minute value and a positive `MusicalTime` beat unit. Its throwing initializer rejects invalid values. `seconds(for:)` maps any musical time using:

```text
seconds = musicalTime / beatUnit * 60 / beatsPerMinute
```

Conversion throws if the result is not finite. It does not change events, score extent, or track metadata. Therefore one `CompiledScore` can be mapped through multiple tempo values without compilation.

## Runtime Flows

```text
Read Music.score
      |
      v
Read one returned Score value
      |
      v
Visit score node -- depth checked at every recursive descent
      |-- expand returned client Score.body
      |-- descend into package group or Track
      |-- register Track metadata -- track limit checked
      |-- append Note event ------- duration, time, event limit checked
      `-- account for Rest -------- extent and time checked
      |
      v
Sort events by (start, traversal ordinal)
      |
      v
Return complete CompiledScore
```

Tempo mapping is a separate pure call after compilation. No wall clock participates in either flow.

## State, Ownership, and Lifecycle

Every declaration, compiler configuration, track descriptor, event, result, and tempo is an immutable `Sendable` value. The compiler owns temporary traversal ordinals and track identifiers for one synchronous call, then discards that state. `CompiledScore` owns its arrays. No view borrows declaration storage, and no process-wide registry or cache exists.

## Failure, Concurrency, and Constraints

`ScoreCompiler.Limits` owns three positive configurable bounds: maximum recursive score-node traversal depth, maximum emitted events, and maximum tracks. Traversal depth counts custom bodies, package-owned groups, and tracks uniformly so deeply nested package values cannot exhaust the call stack outside the bound. Defaults must be documented API constants and large enough for normal interactive scores; tests use smaller explicit values to prove each failure. A zero limit is rejected by a typed limits-construction error or represented by a failable initializer, consistently across all three fields.

Compiler arithmetic uses checked integer operations. It must not use floating-point time internally, silently clamp overflow, skip malformed values, or invoke a terminal `body`. Limits govern compiler traversal only after a score value or client body has returned. Declaration construction and execution inside a client computed `score` or `body` getter occur before the compiler regains control; a getter that traps, loops, or allocates without returning violates the client conformance contract and cannot be converted into a typed package error. Recursive values that return another score are stopped by traversal depth.

Independent compiler and tempo calls may run concurrently. There is no lock because there is no shared mutable state.

## Verification and Change Impact

One focused `SwiftMusicTests` suite must falsify the contract through public APIs:

| Invariant | Required behavioral evidence |
|---|---|
| External declarations execute | A client `Music` containing a client `Score` compiles to its terminal note event without terminal-body access |
| Builder composition is parallel | Two sibling notes both start at their explicit offsets and total extent is their maximum end |
| Builder control flow works | `if`, `if/else`, optional omission, and a finite `for` loop change the emitted public events as declared |
| Track is optional metadata | Untracked notes compile; wrapping the same notes preserves timing; nested and empty track metadata preserves name and parent relationship |
| Rest affects extent only | A rest emits no event and can extend total duration |
| Ordering is deterministic | Equal-time notes remain in declaration traversal order |
| Failures are explicit | Invalid MIDI pitch construction throws its typed error; zero duration, time overflow, deeply nested custom and package-owned score nodes, event limits, and track limits each throw the expected typed compilation case and return no partial result |
| Tempo is separate | One compiled score retains identical beat events while quarter-note 60 BPM and 120 BPM map to different expected seconds |
| Value concurrency contract holds | Swift 6 strict-concurrency compilation accepts the public values as `Sendable` without unchecked conformances |

Changes to `Music`, `Score`, builder parallelism, terminal detection, time arithmetic, event ordering, track identity, extent, errors, or tempo mapping require rerunning the entire focused suite and reviewing the parent module and package assumptions. New rhythm, sequential, meter, dynamics, audio, or editor work requires a separate component design rather than extending this foundation implicitly.
