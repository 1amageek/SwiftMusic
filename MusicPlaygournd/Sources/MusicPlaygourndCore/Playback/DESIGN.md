# Playback

## Purpose and Scope
Component. Parent: [Core](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
AudioLoopEngine owns AVAudioEngine and revision-safe sample transport. Shared state is Mutex-protected on every access. App never mutates playback state directly.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
beginUpdate -> submit prepared candidate -> callback at bar boundary -> adopted loop and snapshot
```

## Contracts and Invariants
Public @MainActor engine: init() throws; beginUpdate(revision: UInt64); submit(loop: PreparedLoop, revision: UInt64) throws; play() throws; stop(); snapshot() -> PlaybackSnapshot. Snapshot fields loop: PreparedLoop?, revision: UInt64?, beatPosition: Double, isPlaying: Bool. New edit clears pending but preserves current. Reject stale/duplicate completions. First loop adopts while stopped. Existing playing loop adopts at next current-meter bar boundary without resetting the accumulated transport clock. Snapshot reports actual adopted PCM. Callback copies bounded PCM, no await/UI/I/O. Immutable buffers retain an off-callback owner to prevent deallocation on callback.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Tests prove render cursor progress through failed/stale updates, boundary changes and stop/resume; AVAudioEngine tests confirm nonzero samples through native path. Mutex copy callback is thread-safe but not a hard-real-time guarantee. All unsafe AudioBufferList borrows are scoped to callback, never escape. Shutdown stops engine before resource release.
