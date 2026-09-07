# MusicPlaygournd

A native macOS editor for making music with SwiftMusic. Write a `Session: Music`, press Play, and keep editing while the last valid loop plays. Swift is compiled automatically after a short typing pause. The editor highlights playing pattern literals and aligns source waveforms to their Swift lines. A stereo waveform and spectrum monitor capture the actual output after the live master effects.

```text
Swift editor -> prepare -> next bar -> audio + rhythm
                  error -> diagnostic; current loop continues
```

## Run

Requires macOS 15+, Swift 6.4 and Xcode command-line tools. This app evaluates trusted local Swift code with your user account's permissions; it is not a code sandbox.

```sh
./Scripts/build-app.sh
open .build/MusicPlaygournd.app
```

The app bundle includes its evaluation package sources. It retains the installed Swift toolchain path used to build it; that toolchain must remain installed. The build is locally ad-hoc signed, not notarized or submitted to the App Store.

## Use

- Play/Pause: Command–Return. Apply immediately: Command–R. Otherwise edits apply automatically after 650 ms without typing.
- Change BPM (40–240), low-pass cutoff, delay mix and reverb mix live with the master sliders. These controls do not compile code or create a new loop revision. Tempo changes preserve pitch.
- Code and quarter-note meter (2/4–7/4) changes prepare a new loop and switch at a bar boundary.
- Open/Save UTF-8 Swift sessions: Command–O / Command–S. Keep the entry type named `Session` and conform it to `Music`.
- Click the diagnostic heading to select a reported Swift source line. Direct pattern literals glow while their compiled source events play.
- Inline results appear after the final modifier of each compiler-mapped sound expression by default. Time runs horizontally; notes use vertical pitch lanes. Result cards scroll with the source and never become part of the saved Swift text.
- Use the layout selector to switch between inline results, the attached side timeline, and the bottom overview.

## Swift completion

Type a dot or pause while typing an identifier to request semantic Swift completion. Control–Space requests it manually. Select a signature and press Return or Tab; the first argument is selected for replacement. Browsing candidates does not edit the source or prepare audio. Candidate insertion is one undoable edit. The first request prepares the SwiftMusic module; later requests reuse the server. Completion uses the installed toolchain's SourceKit-LSP in a separate workspace and reports unavailable-server errors in the status bar.

## Patterned rhythm and gain

```swift
Sample("kick")
    .rhythm("x [x x] ~ x")
    .gain("1 [0.3 0.6] 0 0.8")
```

Brackets subdivide one parent slot. Gain patterns repeat over their cycle and select a value at each event onset, holding it for that voice. Patterned gain applies before mixing; numeric `.gain(0.5)` retains its existing post-mix behavior. Rhythm and note leaf tokens glow; gain literals currently affect the sound and waveform but are not highlighted.

## Playback support

| Supported | Behavior |
|---|---|
| `Sample("kick")`, `Sample("snare")`, `Sample("closedHat")` | Original built-in percussion sounds |
| `Synthesizer(.sine/.square/.saw/.triangle/.noise)` | Basic oscillator voices |
| Nested `[]` rhythm/notes, per-event gain patterns, transpose, chords, velocity, gate | Compiled by SwiftMusic, rendered as events |
| Gain, pan, mute | Applied in render-plan order |
| Live master tempo, low-pass, delay, reverb | Native AVFAudio processing while playing |
| Other source settings, code-declared effects, buses | Explicit unsupported-feature diagnostic; current audio survives |

This first version prepares finite PCM loops offline. Loops are padded to whole bars, bounded to 32 beats and 16 seconds. Source, event and graph limits bound preparation work. Synth voices use short edge fades. Master delay/reverb continue across loop changes; Pause stops output and clears monitoring. Arbitrary sample files are not implemented. The callback is synchronized and bounded, without a hard real-time latency guarantee. Line anchors come from the Swift compiler. Deleted anchors become unmapped until a new successful evaluation. Escaped, multiline, ambiguous or nonliteral pattern expressions are not assigned guessed text highlights. Only the individual token identified by the currently playing compiled event glows; repeated and shifted events preserve that token association. Source waves are pre-mix (including per-event gain, before scalar gain/pan/mute). The bottom stereo waveform and spectrum use a bounded 2,048-frame capture after master effects, before hardware volume; they are not microphone or hardware loopback. Playback cursor latency compensation uses AVFAudio presentation metadata; this is not sample-accurate device loopback synchronization.

See [DESIGN.md](DESIGN.md) for ownership and failure contracts. This development app uses the adjacent SwiftMusic workspace for source provenance, which is not yet in the published 0.1.0 release. The app bundles both source packages so it can evaluate sessions when moved. No new library release is created by this change.

## Verification

On macOS 27.0 arm64 with Swift 6.4 snapshot 2026-08-14, 40 SwiftMusic tests, 24 focused editor/runtime tests, and a native hardware-output tap test passed. Native DSP tests verify tempo/pitch, neutral gain, filter attenuation and delay/reverb tails; model tests verify controls allocate no evaluation revision. The unchanged evaluator's real compilation/failure/cancellation/timeout/recovery test passed in 54 seconds for the nested-pattern change. Repeating that long test during active editor compilations reached its 120-second outer budget while still building; its previous evidence is retained, and the changed hardware-output path was verified separately. Release builds pass with development-toolchain object verification warnings. Visible checks cover nested leaf highlighting, aligned scrolling, post-FX monitoring, live controls and open/save. This does not claim tested macOS 15 runtime behavior or hard real-time scheduling.

Twelve completion/control tests pass, including real SourceKit-LSP gain overloads, UTF-16 edits, initial-request cancellation, recovery, malformed frames, unresponsive-server timeout, process shutdown, candidate navigation, insertion and Undo. The cold semantic service test completed in 8.574 seconds. In the optimized app, automatic gain overloads, arrow navigation without edits, Return acceptance with argument selection, one Undo, and a single pan candidate without automatic insertion were verified while the previous loop and output monitoring continued through invalid edits.

The app build script disables the Swift 6.4 2026-08-14 snapshot compiler's debug-type round-trip assertion, which crashes on optimized `FileHandle.AsyncBytes` code. This is a compiler diagnostic workaround; optimization remains enabled.

Inline results are verified with native AppKit layout and bitmap drawing: same-line stacking, source/selection/undo preservation, layout removal, anchor remapping, and first-frame label sizing. Four completion tests and two literal-highlighting regressions also pass.

The final-expression update passed nine focused tests, including actual Swift compilation with nested tracks, multiline modifiers, Unicode source, final result lines, transposed MIDI notes, failure/cancellation/timeout/recovery, independent pattern/result remapping, native viewport coordinates, and completion. The real evaluator test completed in 207.627 seconds under machine load.

The final optimized Results app visibly places grids after the complete modifier/Track expressions. Scrolling preserves the Bass pitch lanes and moving cursor; exact pattern tokens and master monitoring remain active. Switching back to Side Timeline aligns rows with lines 7, 13 and 20. A further invalid-edit UI probe was stopped before mutation because the user was operating the app; failure evidence combines the real evaluator test with the earlier inline playback-retention check.
