# Editor

## Purpose and Scope
Component. Parent: [App](../DESIGN.md). Children: none.

## Responsibilities and Boundaries
MainActor session model owns editable source, revision allocation, evaluation task, diagnostics, open/save and UI state.

## Related Designs
Use the parent/child links above. Dependencies: SwiftMusic owns event semantics; Core owns rendering/playback/evaluation contracts; App consumes Core.

## Architecture
```text
edit -> invalidate pending -> debounce -> evaluate -> submit -> snapshot -> rhythm Canvas
```

## Contracts and Invariants
Left native text editor and right rhythm view; optional bottom layout. Clickable compiler diagnostics select source line. Track labels derive from compiled metadata; exact literal track-name navigation is a convenience, not general source instrumentation. Preparing/error states explicitly distinguish edited code from playing revision. Pause preserves cursor. Open/save uses UTF-8 .swift, edits preserved on canceled panels. No autosave or general inline source map in this version.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
UI check exercises edit, invalid input preserving old visible rhythm/audio, BPM change, stop/resume and file save/reopen. Tests assert model revision rules; parent owns cumulative integration.
