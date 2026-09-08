# LiveUpdates

## Purpose and Scope

This component owns preparation results and revision-safe adoption of musical plans for MusicPlaygournd and other hosts. Parent: [SwiftMusic module](../DESIGN.md). No children. This is plan-state management, not audio playback or resource readiness.

## Responsibilities and Boundaries

`LiveMusicUpdate` owns the result of synchronous plan preparation. `LiveMusicState` owns current, pending, and diagnostic values. Hosts allocate monotonically increasing revisions, isolate each mutable state instance, prepare outside the audio callback, validate backend resources, and call adoption at their chosen musical boundary. This component owns no host scheduling, clock, PCM, device, or audio continuity; its optional Observation session uses only a bounded callback hop to MainActor and never schedules preparation or adoption itself.

For an audio host, resource preparation belongs between `LiveMusicUpdate.prepare` and `receive`: the host delivers exactly one final prepared or failed completion after its backend work finishes. A plan-only client may receive immediately. A host must not first deliver a prepared result and then expect a second backend-failure completion for the same revision to be accepted; duplicate rejection is deliberate.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | public exports | Exports live update values | No shared storage |
| [SoundComposition](../SoundComposition/DESIGN.md) | depends on | SoundCompiler, CompiledSound, SoundCompilationError | Prepares declarations as plans | Successful compilation is not backend readiness |

## Architecture

```text
edit arrives -> state.beginUpdate(revision)
                     |
Music / Sound -> LiveMusicUpdate.prepare -> state.receive(result)
                                             |
                            pending plan or diagnostic
                                             |
host musical boundary -> adoptPendingAtBoundary -> current plan
```

## Contracts and Invariants

- `LiveMusicUpdate: Sendable, Equatable` has `prepared(revision: UInt64, sound: CompiledSound)` and `failed(revision: UInt64, error: SoundCompilationError)` cases.
- Nonthrowing static `prepare(revision:music:using:)` and `prepare(revision:sound:using:)` use `SoundCompiler` (default instance) internally. Every failure is retained as a failed result; no empty plan is substituted.
- `LiveMusicState: Sendable, Equatable` is a value with a public empty initializer and externally read-only `currentSound`, `currentRevision`, `pendingSound`, `pendingRevision`, `diagnostic`, `diagnosticRevision`, `latestRevision`, and `preparingRevision`, initially nil.
- `beginUpdate(revision:) -> Bool` accepts only a revision greater than the latest, or any initial revision (including zero). It records latest/preparing and clears pending/diagnostic without changing current. Equal/older revisions return false without mutation. The host must call it at edit arrival, before preparation.
- `receive(_:) -> Bool` accepts only a completion matching `preparingRevision`. Acceptance clears preparing; prepared sets pending and failed sets diagnostic. It never changes current. Duplicated, unsolicited, and stale completions return false without mutation.
- `adoptPendingAtBoundary() -> CompiledSound?` is the only operation replacing current. It moves a pending plan/revision to current and clears pending, returning the adopted plan. Without pending it returns nil and preserves current. It neither verifies a boundary nor advances/resets transport time.
- A newer edit invalidates an older pending plan immediately. In particular, revision 1 finishing after revision 2 begins cannot be adopted, even before revision 2 finishes.
- An initial failure leaves current nil. A later failure preserves the last adopted plan. Explicit silent musical content is distinct from failure.

## Runtime Flows

| Input | Pending/preparing result | Current result |
|---|---|---|
| New edit | Old pending cleared; new preparing revision | Preserved |
| Matching preparation success | Pending plan; preparation finished | Preserved |
| Matching failure | Diagnostic; no pending or preparing | Preserved |
| Old or duplicate completion | No change | Preserved |
| Host adoption with pending | Pending cleared | Replaced atomically as a value |

### Observed performance preparation

`@MainActor PerformanceObservationSession<Base>` owns one resolved `PerformanceMusic<Base>`, its supplied model references, a compiler, and one invalidation generation. Each `prepare(revision:liveLoop:)` validates requirements before body access and evaluates body once under `withObservationTracking`, returning the ordinary nonthrowing `LiveMusicUpdate` success or its existing `SoundCompilationError` failure mapping. New `prepareDetailed(liveLoop:) throws -> CompiledSound` performs the same single tracked body evaluation through `SoundCompiler.compileDetailed`; it preserves `LocatedSoundCompilationError` unchanged for hosts that map compiler provenance and never first calls `prepare`. The existing nonthrowing method's result and failure behavior do not change. The Observation callback is one-shot: it coalesces repeated changes into one MainActor notification for the current generation, and the host calls one preparation method again to re-arm tracking. `invalidate()` makes every outstanding callback inert and releases the session's model references; no callback compiles, renders, mutates `LiveMusicState`, or crosses an audio callback by itself.

All `LiveMusicUpdate` overloads that accept `Music` or `PerformanceMusic` are MainActor-isolated and use the same pre-body resolver as `SoundCompiler`; Sound overloads and `LiveMusicState` remain unchanged. A model change creates a new candidate only. Existing revision checks and host boundary adoption continue to preserve the current sound on missing injection, invalid state, stale completion, cancellation, or compilation failure.

## State, Ownership, and Lifecycle

`LiveMusicState` storage is ordinary value storage using the existing copy-on-write arrays in immutable compiled plans; copying it creates independent value semantics and retains at most one current and one pending plan. `PerformanceObservationSession` is the separate optional MainActor reference owner described above and never enters `LiveMusicState`. A host must isolate mutation of its state instance. Preparation may occur independently; revisions associate completions with edits.

## Failure, Concurrency, and Constraints

Revision allocation belongs to the host; the component never increments or wraps UInt64. Preparation retains compiler limits. No realtime scheduling or concurrent shared-state guarantee is inferred from `Sendable`. Swift source evaluation and backend failures can be forwarded by the host as explicit failed updates; this component does not evaluate Swift source or prepare audio resources.

## Verification and Change Impact

Focused tests must cover initial success/failure, replacement at adoption only, invalid literal preservation, pending invalidation at edit start, duplicate/out-of-order completions, zero/max revisions, independent value copies, observed change coalescing/re-arm/invalidation, missing performance injection before body, and one-evaluation detailed success plus exact located failure. Root-owned [LiveDSLIntegrationTests](../../../Tests/SwiftMusicTests/LiveDSLIntegrationTests.swift) exercises the exact philosophy example and the real preparation-to-adoption path. Changes to revision, performance resolution or preparation contracts require parent and SoundComposition compatibility review. Tests prove plan-state behavior only, not audible continuity.
