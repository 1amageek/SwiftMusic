# Evaluation

## Purpose and Scope
Component. Parent: [Core](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
SourceEvaluator owns generated SwiftPM evaluation workspace and subprocess lifetime. SwiftCompletionService owns a separate SourceKit-LSP workspace and process. Caller owns edit revisions/debounce and completion presentation.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
Session: Music source -> compiler + JSON AST -> executable -> LoopRenderer -> result-line enrichment -> validated loop
editable Swift -> dedicated SwiftPM workspace -> SourceKit-LSP -> semantic completion result
```

## Contracts and Invariants
Evaluate real Swift, not a DSL text parser. User defines Session: Music. Wrapper uses #sourceLocation Session.swift for diagnostics. Serialize mutable scratch workspace explicitly across actor reentrancy. Cancellation/timeout kills complete subprocess process group and waits for cleanup before reusing workspace. Build limit120s; execution10s; diagnostic output1MiB; result bounded16MiB; source64KiB. The /usr/bin/python3 process-group launcher drains a pipe in 64 KiB chunks and caps accepted diagnostics before writing. Foundation terminationHandler publishes completion through a Mutex; no blocking wait crosses actor suspension. Decode and validate output before submit. Failed edits leave transport unchanged.

After a successful compile, SourceEvaluator asks the same Swift 6.4 toolchain to emit JSON AST with `-dump-ast -dump-ast-format json`. The AST input contains only the evaluation import prefix plus the unchanged user source, without the generated entry point; the known prefix UTF-8 length maps user Session.swift line/column anchors into compiler byte ranges. The invocation uses the built module search paths and suppresses warnings so merged diagnostics cannot corrupt successful JSON. For each decoded row with a Session.swift pattern anchor, evaluation selects the outermost explicit `call_expr` containing that bounded UTF-8 byte position and records the expression end line, adjusted back to the user source, as `LoopRow.resultLine`. Implicit calls are excluded. Missing, malformed, ambiguous, oversized, or unsupported AST provenance is a typed evaluation failure; evaluation never guesses chain endings from source text. AST output shares the existing 1 MiB process-output bound and cancellation/process-group lifecycle.

`SwiftCompletionService` is an actor initialized with `packageURL`, `workspace`, and `sourceKitLSPExecutable`. `completions(source:utf16Offset:) async throws -> [SwiftCompletion]` returns semantic candidates with `label`, optional `detail`, `insertion`, a document-relative UTF-16 `replacementRange`, and an insertion-relative optional `selectionRange`; `shutdown()` terminates the server and removes its workspace. The workspace depends on the same bundled SwiftMusic package used by evaluation, but has an independent source file and scratch path. Requests use LSP UTF-16 coordinates at the identifier start, as required by the bundled SourceKit completion engine. The completion-only document omits the typed prefix so SourceKit sees the completion point; the original editor/evaluator source is unchanged. An initial `workspace/synchronize(index: true)` barrier prepares dependencies, with a 60-second bound, without a fixed delay. Subsequent completion requests have a 30-second bound. The service filters labels by the typed prefix and maps the returned replacement through that prefix; it never changes characters outside the server edit and typed prefix. SourceKit snippets are decoded into insertion text and the first argument selection. Malformed ranges or unsupported snippet forms fail or discard the affected candidate instead of applying a guessed edit.

Only the latest source/cursor request may be delivered. Cancellation and bounded timeout cancel the request; protocol failure or server exit returns a typed diagnostic and permits one clean lazy restart. Message size, candidate count, source size, and process lifetime are bounded. Completion never calls SourceEvaluator, allocates an audio revision, submits a loop, or touches adopted audio. Toolchain-specific `sourcekit-lsp` absence is explicit rather than silently switching toolchains.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Integration tests execute evaluation success, syntax error, invalid pattern, runtime timeout, cancellation and recovery. Completion integration opens the real package and proves SwiftMusic modifier/type overloads, including gain signatures, replacement ranges and first-argument selection; it also proves stale/cancel/failure recovery and bounded shutdown without orphan processes. Native compiler/LSP failure is visible, never an empty successful result. Process-specific Application Support workspaces are excluded from Git and independently removed on orderly shutdown. Crash leftovers are not automatically pruned.

### Source line anchors
SourceLineMap owns UTF-16 offsets for the union of compiler-provided Session.swift pattern lines and AST-derived result lines. Native edit ranges are applied before text mutation; unaffected anchors shift by the replacement length delta, anchors removed by an edit become unmapped, and current line lookup uses native newline semantics. Pattern and result lookup remain separate so edits cannot substitute one placement authority for the other. Source is bounded by the editor 64 KiB evaluation limit. Tests cover insertion, deletion, Unicode, stale revisions, and independently shifted/removed pattern and result anchors. App owns maps for current and pending revisions; opening a different document clears associations.
