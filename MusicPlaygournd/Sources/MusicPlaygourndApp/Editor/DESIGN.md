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
latest evaluation/completion status -> bottom Logs disclosure -> optional source reveal
adopted control catalog -> complete override generation -> retained worker rerender -> same-revision crossfade
```

## Contracts and Invariants
The editor owns inline, side, and bottom result layouts; inline is the default. Native NSTextView layout remains the authority for compiler-captured source lines. Pattern anchors own token glow and side-timeline alignment, while compiler-derived result lines own inline placement after the complete sound expression. Each result shows actual pre-mix PCM peaks, compiled event timing, and the adopted transport cursor. The bottom monitor shows actual post-FX stereo waveform and spectrum from the playback tap. No independent musical or Swift parser and no per-row transport exists.

### Inline results

Inline rhythm/note results are read-only child views of the NSTextView document view, so code and results share one native vertical and horizontal scroll coordinate space. For each adopted row, `LoopRow.resultLine` is the end line of the outermost explicit Swift call expression containing its compiler pattern anchor; the card is placed after that result line, below all chained modifiers. `NSLayoutManagerDelegate` reserves paragraph spacing there without inserting characters or mutating text-storage attributes. Sources with the same result line share one contiguous bounded region and stack deterministically. Each card uses horizontal beat time and a moving transport cursor. Note events use vertical MIDI pitch lanes with higher pitches above lower pitches; non-pitched rhythm events use a named source lane. Event start and audible duration come from the adopted LoopEvent, while the existing pre-mix peaks may remain a secondary signal trace rather than replace the event grid. Rows without a current result-line mapping are omitted from inline placement and remain represented by the existing alternate views.

A `LoopEvent` marked `wrapsLoopBoundary` is one musical event and one lexical token. Inline, side and bottom visualizations split only its geometry at the right/left window edges. Playback highlighting evaluates its circular active interval, keeping the original token active across beat zero; it does not synthesize a beat-zero onset, token or source association.

Changing layout, adopting a loop, moving the transport, or relaying out cards must preserve the exact source string, UTF-16 offsets, glyph-to-character mapping, selection, undo stack, completion snapshot/ranges, and syntax/token temporary attributes. Cards never intercept editing or synthesize source content. An invalid or stale edit keeps the adopted revision's cards and PCM visible, with both pattern and result anchors transformed by the current SourceLineMap. Inline, side, and bottom use the same adopted PreparedLoop and beat position; the layout control only changes presentation. Side coordinates are converted through the native editor-to-clip-view transform rather than reconstructed from scroll offsets.

A source map belongs to its submitted revision and becomes visible only when that revision is adopted. Exact text edits shift untouched anchors; deletion of an anchor removes its association until successful evaluation. Unmapped sources are counted explicitly. Failed edits preserve adopted audio and wave data. The UI distinguishes playing and edited revisions. Clickable compiler diagnostics select source lines. Open/save uses UTF-8 .swift and preserves edits on canceled panels.

### Logs pane

ContentView presents one dedicated `Logs` disclosure below the spectrum and above the status bar. It is collapsed by default and preserves the user's explicit expanded/collapsed choice for the current view lifetime. The collapsed label always exposes the current error count; the expanded content shows the latest evaluation diagnostic and latest completion status from SessionModel, and retains the existing source-reveal action for a diagnostic with a Session.swift location. Moving this presentation out of the editor must keep the CodeEditor view identity, source, selection, undo stack, completion state, adopted revision, playback, and visualization unchanged. Logs owns presentation only: it does not collect history, create a logging backend, or reinterpret diagnostics.

TimelineTextView requests semantic completion automatically after a dot or identifier typing pause and manually with Control-Space. An AppKit popover and table present signature-bearing labels while keyboard focus remains in the editor. Up/Down only move selection; Return/Tab explicitly accept and Escape dismisses without mutation. Results are cached only for the exact source snapshot, UTF-16 cursor, and request generation. Final acceptance applies the candidate replacement once through validated NSTextView editing, creates one undoable source edit, and selects the first snippet argument when present. Any intervening edit, selection move, cancellation, or completion failure dismisses the result without changing source, revision, anchors, diagnostics, or adopted playback. Full IDE navigation, refactoring, formatting, and keyword-only fallback are outside this component. The custom presentation is required because native `NSTextView.complete` commits preview selection on candidate navigation.

Dense native controls use 8/13/21 spacing and mint/cyan on dark surfaces. Native line metrics override spacing tokens for exact alignment. Wave amplitude and spectrum height encode actual signal values, not decorative animation. Text labels and accessibility descriptions accompany color.

## Failure, Concurrency, and Constraints
Failure is reported as a diagnostic or typed error; the last adopted loop survives edit failures. Mutable host state is MainActor- or Mutex-isolated.

## Verification and Change Impact
Focused AppKit tests prove inline spacing and card rects appear below compiler-derived final modifier lines, including a final line at EOF; same-line results group; inline-to-side switching and scrolling preserve native line/card offsets; and layout updates leave source length/content, selection and undo state unchanged. Real-compiler fixtures cover nested tracks, multiline chains, transposition, strings and comments. Existing completion and token tests must remain green. A Release build plus native UI check proves Logs is initially collapsed with the current error count, expands to the latest diagnostic/completion information and source-reveal action, collapses again, and never changes source or the adopted playback state. A separate Release app instance verifies inline default, moving playback, failed-edit retention, code/result scrolling, and switching among inline/side/bottom without touching the user's running app. Parent owns cumulative integration.

### Live master controls
SessionModel always asks evaluation to prepare PCM at 120 BPM. Live BPM 40...240 changes only the engine rate and must not schedule evaluation, allocate a revision, or replace pending/current loops. Low-pass cutoff and delay/reverb wet controls follow the same live path with neutral defaults. The UI displays typed control failures while retaining the last valid setting. Token/cursor display uses the engine's latency-adjusted beat; master waveform/spectrum use only the latest bounded post-FX snapshot and show zero while paused.

### P05 live-control session

SessionModel owns the MainActor composition of retained evaluation, transport adoption and control UI state. Each source evaluation calls `evaluateRetained` with its allocated revision, stores the returned candidate catalog and line map, and submits only its initial loop to AudioLoopEngine. A candidate remains owned by SourceEvaluator while that exact revision is pending in transport. Cancellation or a newer edit may discard a candidate only after `beginUpdate` has invalidated the same pending engine revision; it may never leave a submit-capable pending loop whose worker has already been destroyed.

`refresh()` observes revision and override generation. When transport first reports a candidate revision as adopted, SessionModel awaits `evaluator.adopt(revision:)`; source/node/Track controls remain unavailable during this handshake. Only a true result followed by `controlsAvailable(revision:) == true` publishes that catalog and enables its addresses. False keeps adopted PCM, states that controls are unavailable for that revision, and sends no request to a missing worker. After an ordinary override error SessionModel queries the same typed lifecycle state: true preserves enabled controls and reports only that request failure, while false disables compiled controls after a fatal worker fault. It never classifies failure by parsing diagnostic text. Promotion retires the prior worker only through SourceEvaluator's lifecycle contract. An adoption task publishes only while the engine snapshot still reports that adopted revision and the task remains current; a newer failed or pending edit revision does not disable the still-adopted revision's controls.

While compiled controls are enabled, SessionModel starts at most one MainActor health-check Task and polls `controlsAvailable` no more than once per second. This bounded UI observation detects a passive worker exit without waiting for a gesture; false disables compiled controls, preserves PCM and publishes one diagnostic. The poll performs no work on the audio callback, never changes source/edit revision and is canceled and awaited during model shutdown. One second is the app's observation cadence, not a worker liveness timeout or audio guarantee.

Source/node/Track gesture state is a dictionary keyed by the complete adopted `LiveControlAddress`. Each accepted change increments one bounded `UInt64` generation and sends the complete override set through `evaluator.render`; release removes only that address and sends the remaining set. A newer gesture cancels the prior host render task. Only a result matching the current revision and latest generation reaches `engine.replace`; stale success, cancellation and typed render failure do not alter loop, catalog, source, edit revision, line maps or the last applied override set. The applied set advances only after `PlaybackSnapshot.overrideGeneration` reports it active. Fatal worker failure preserves playback, disables all compiled controls and remains visible until a new code revision adopts.

Master controls remain the existing synchronous MainActor engine path. BPM, low-pass, delay and reverb persistent targets survive code adoption. A temporary master gesture remembers that host-owned target, writes through the existing P04 setter, and release restores it. New code issues fresh revision-scoped master addresses over the same native owners; old handles fail stale and no adoption resets or replays a master target. Editor control changes never mutate the Swift source, completion request/snapshot, undo stack, compiler anchors, evaluation revision or bar-adoption state.

Focused SessionModel Swift Testing proves: candidate ownership through delayed bar adoption; invalidation-before-discard on a newer edit; adoption-handshake availability; complete-set latest-generation replacement/release; stale and failed result preservation; fatal-worker unavailable state; source/node/Track address invalidation on code adoption; persistent master values with fresh addresses; and zero source/undo/completion changes. Integration measures audible source, subtree and Track overrides plus native masters, exact 30-millisecond handover and active generation while failed Swift edits retain the adopted worker/audio.

### Inline playing literals
The adopted compiled patternText and tracked source line identify an exact, unique plain string literal on that line. Compiler-provided event patternStepIndex identifies the whitespace-delimited token within that exact literal. Only tokens whose actual events contain the transport beat glow. Offsets, repeats and speed changes use transformed event timing; the editor never infers token timing. Rest tokens do not trigger notes. Escaped/interpolated, multiline, ambiguous or nonliteral expressions receive no guessed range; line-aligned waveforms remain available. Temporary layout attributes never change saved source or undo history.

### Nested mini-notation
Bracket characters are lexical delimiters, not sounding tokens. Exact direct-literal highlighting uses compiler leaf indices and final event times, including uneven nested subdivisions. Gain-pattern values affect voice PCM and master monitoring; gain-literal highlighting is not provided in this increment. Zero-gain events remain on the rhythmic grid but do not illuminate sounding tokens.

CompletionTextView owns an NSPopover with an NSTableView. Arrow keys change selection, Return/Tab or a row click accept, and Escape dismisses. Even a single candidate requires acceptance. NSTextView retains keyboard focus and candidate browsing never calls text insertion.
