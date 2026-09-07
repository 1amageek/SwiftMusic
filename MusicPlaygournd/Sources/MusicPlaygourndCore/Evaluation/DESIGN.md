# Evaluation

## Purpose and Scope
Component. Parent: [Core](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
SourceEvaluator owns generated SwiftPM workspace and subprocess lifetime. Caller owns edit revisions/debounce.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
Session: Music source -> compiler -> executable -> LoopRenderer -> binary property list -> validated loop
```

## Contracts and Invariants
Evaluate real Swift, not a DSL text parser. User defines Session: Music. Wrapper uses #sourceLocation Session.swift for diagnostics. Serialize mutable scratch workspace explicitly across actor reentrancy. Cancellation/timeout kills complete subprocess process group and waits for cleanup before reusing workspace. Build limit120s; execution10s; diagnostic output1MiB; result bounded16MiB; source64KiB. The /usr/bin/python3 process-group launcher drains a pipe in 64 KiB chunks and caps accepted diagnostics before writing. Foundation terminationHandler publishes completion through a Mutex; no blocking wait crosses actor suspension. Decode and validate output before submit. Failed edits leave transport unchanged.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Integration tests execute success, syntax error, invalid pattern, runtime timeout, cancellation and recovery. Native compiler/build process failure is visible, never an empty successful result. Compiler cache is a process-specific local Application Support directory, excluded from Git. Normal app termination cancels evaluation, awaits child cleanup, then shutdown removes that workspace. Crash leftovers are not automatically pruned.

### Source line anchors
SourceLineMap owns UTF-16 offsets for compiler-provided Session.swift lines. Native edit ranges are applied before text mutation; unaffected anchors shift by the replacement length delta, anchors removed by an edit become unmapped, and current line lookup uses native newline semantics. Source is bounded by the editor 64 KiB evaluation limit. Tests cover insertion, deletion, Unicode and stale-revision mappings. App owns maps for current and pending revisions; opening a different document clears associations.
