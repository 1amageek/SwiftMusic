# MusicPlaygournd

## Purpose and Scope
Standalone macOS 15+ live Swift editor; the native package owns the app and host runtime. Parent: none. Children: [Core](Sources/MusicPlaygourndCore/DESIGN.md), [App](Sources/MusicPlaygourndApp/DESIGN.md).

## Responsibilities and Boundaries
Uses the local SwiftMusic workspace for unreleased additive source provenance and creates no library tag or release. The movable app bundle contains that exact source package. Editor code is trusted local Swift, evaluated in a separate process, not a security sandbox. Playback, transport, rendering, file editing, diagnostics, and visualization belong to this package.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
Swift source -> bounded evaluation -> PCM + anchored rows -> bar-boundary adoption -> audio + aligned rows + analyzers
```

## Contracts and Invariants
The current audio and view use the same immutable prepared loop and sample cursor. Player rows use compiler provenance and native editor geometry; exact direct literals use compiled pattern text and event step provenance to illuminate only active tokens. New edits invalidate pending updates immediately. Failure/stale results never replace current audio or visualization. BPM is separate from code. Unsupported backend features fail explicitly.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Run core behavioral tests, real compiler good/bad/recovery checks, AVAudioEngine output checks and live UI. Scripts/build-app.sh bundles source for evaluation and records the installed Swift executable. App runtime needs Swift 6.4 and Xcode command-line tools including Python3. No App Store, notarization or public app release is claimed.
