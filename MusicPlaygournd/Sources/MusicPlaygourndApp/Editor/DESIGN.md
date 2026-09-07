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
The editor owns an attached timeline gutter. Native NSTextView line fragment rectangles and clip bounds align each row to its compiler-captured pattern line and synchronize vertical scrolling. Multiple sources at one location share the row. Each row shows actual pre-mix PCM peaks, normalized by its peak for display and labeled AUTO SCALE, and compiled note timing; the bottom monitor shows post-mix spectrum from the adopted loop and transport cursor. No independent musical parser or per-row transport exists. The optional bottom overview remains available.

A source map belongs to its submitted revision and becomes visible only when that revision is adopted. Exact text edits shift untouched anchors; deletion of an anchor removes its association until successful evaluation. Unmapped sources are counted explicitly. Failed edits preserve adopted audio and wave data. The UI distinguishes playing and edited revisions. Clickable compiler diagnostics select source lines. Open/save uses UTF-8 .swift and preserves edits on canceled panels.

Dense native controls use 8/13/21 spacing and mint/cyan on dark surfaces. Native line metrics override spacing tokens for exact alignment. Wave amplitude and spectrum height encode actual signal values, not decorative animation. Text labels and accessibility descriptions accompany color.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
UI check exercises edit, invalid input preserving old visible rhythm/audio, BPM change, stop/resume and file save/reopen. Tests assert model revision rules; parent owns cumulative integration.

### Inline playing literals
The adopted compiled patternText and tracked source line identify an exact, unique plain string literal on that line. Compiler-provided event patternStepIndex identifies the whitespace-delimited token within that exact literal. Only tokens whose actual events contain the transport beat glow. Offsets, repeats and speed changes use transformed event timing; the editor never infers token timing. Rest tokens do not trigger notes. Escaped/interpolated, multiline, ambiguous or nonliteral expressions receive no guessed range; line-aligned waveforms remain available. Temporary layout attributes never change saved source or undo history.
