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
dot/word or Control-Space -> semantic request -> AppKit popover completion panel -> validated source edit
```

## Contracts and Invariants
The editor owns an attached timeline gutter. Native NSTextView line fragment rectangles and clip bounds align each row to its compiler-captured pattern line and synchronize vertical scrolling. Multiple sources at one location share the row. Each row shows actual pre-mix PCM peaks, normalized by its peak for display and labeled AUTO SCALE, and compiled note timing. The bottom monitor shows actual post-FX stereo waveform and spectrum from the playback tap. No independent musical parser or per-row transport exists. The optional bottom overview remains available.

A source map belongs to its submitted revision and becomes visible only when that revision is adopted. Exact text edits shift untouched anchors; deletion of an anchor removes its association until successful evaluation. Unmapped sources are counted explicitly. Failed edits preserve adopted audio and wave data. The UI distinguishes playing and edited revisions. Clickable compiler diagnostics select source lines. Open/save uses UTF-8 .swift and preserves edits on canceled panels.

TimelineTextView requests semantic completion automatically after a dot or identifier typing pause and manually with Control-Space. An AppKit popover and table present signature-bearing labels while keyboard focus remains in the editor. Up/Down only move selection; Return/Tab explicitly accept and Escape dismisses without mutation. Results are cached only for the exact source snapshot, UTF-16 cursor, and request generation. Final acceptance applies the candidate replacement once through validated NSTextView editing, creates one undoable source edit, and selects the first snippet argument when present. Any intervening edit, selection move, cancellation, or completion failure dismisses the result without changing source, revision, anchors, diagnostics, or adopted playback. Full IDE navigation, refactoring, formatting, and keyword-only fallback are outside this component. The custom presentation is required because native `NSTextView.complete` commits preview selection on candidate navigation.

Dense native controls use 8/13/21 spacing and mint/cyan on dark surfaces. Native line metrics override spacing tokens for exact alignment. Wave amplitude and spectrum height encode actual signal values, not decorative animation. Text labels and accessibility descriptions accompany color.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
UI check exercises edit, semantic dot/word and Control-Space completion, overload signature display and argument selection, invalid input preserving old visible rhythm/audio, BPM change, stop/resume and file save/reopen. Tests prove preview does not edit, stale results cannot apply, acceptance uses one ordinary edit/undo path, and completion failure preserves source/anchors/playback. Parent owns cumulative integration.

### Live master controls
SessionModel always asks evaluation to prepare PCM at 120 BPM. Live BPM 40...240 changes only the engine rate and must not schedule evaluation, allocate a revision, or replace pending/current loops. Low-pass cutoff and delay/reverb wet controls follow the same live path with neutral defaults. The UI displays typed control failures while retaining the last valid setting. Token/cursor display uses the engine's latency-adjusted beat; master waveform/spectrum use only the latest bounded post-FX snapshot and show zero while paused.

### Inline playing literals
The adopted compiled patternText and tracked source line identify an exact, unique plain string literal on that line. Compiler-provided event patternStepIndex identifies the whitespace-delimited token within that exact literal. Only tokens whose actual events contain the transport beat glow. Offsets, repeats and speed changes use transformed event timing; the editor never infers token timing. Rest tokens do not trigger notes. Escaped/interpolated, multiline, ambiguous or nonliteral expressions receive no guessed range; line-aligned waveforms remain available. Temporary layout attributes never change saved source or undo history.

### Nested mini-notation
Bracket characters are lexical delimiters, not sounding tokens. Exact direct-literal highlighting uses compiler leaf indices and final event times, including uneven nested subdivisions. Gain-pattern values affect voice PCM and master monitoring; gain-literal highlighting is not provided in this increment. Zero-gain events remain on the rhythmic grid but do not illuminate sounding tokens.

CompletionTextView owns an NSPopover with an NSTableView. Arrow keys change selection, Return/Tab or a row click accept, and Escape dismisses. Even a single candidate requires acceptance. NSTextView retains keyboard focus and candidate browsing never calls text insertion.
