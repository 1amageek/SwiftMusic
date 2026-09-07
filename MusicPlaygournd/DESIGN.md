# MusicPlaygournd

## Purpose and Scope
Standalone macOS 15+ live Swift editor; the native package owns the app and host runtime. Parent: none. Children: [Core](Sources/MusicPlaygourndCore/DESIGN.md), [App](Sources/MusicPlaygourndApp/DESIGN.md).

## Responsibilities and Boundaries
Uses published SwiftMusic 0.1.0 without modifying its public contracts. Editor code is trusted local Swift, evaluated in a separate process, not a security sandbox. Playback, transport, rendering, file editing and diagnostics belong to this package.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
Swift source -> bounded evaluation -> prepared PCM and events -> bar-boundary adoption -> audio and rhythm view
```

## Contracts and Invariants
The current audio and view use the same immutable prepared loop and sample cursor. New edits invalidate pending updates immediately. Failure/stale results never replace current audio. BPM is separate from code. Unsupported backend features fail explicitly.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Run core behavioral tests, real compiler good/bad/recovery checks, AVAudioEngine output checks and live UI. Scripts/build-app.sh bundles source for evaluation and records the installed Swift executable. App runtime needs Swift 6.4 and Xcode command-line tools including Python3. No App Store, notarization or public app release is claimed.
