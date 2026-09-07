# MusicPlaygournd

A native macOS editor for making music with SwiftMusic. Write a `Session: Music`, press Play, and keep editing while the last valid loop plays. Swift is compiled automatically after a short typing pause. The editor highlights playing pattern literals and aligns source waveforms to their Swift lines. A stereo waveform and spectrum monitor follow the adopted audio transport.

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
- Change BPM (40–240) and quarter-note meter (2/4–7/4) independently of source. Prepared changes switch at a bar boundary.
- Open/Save UTF-8 Swift sessions: Command–O / Command–S. Keep the entry type named `Session` and conform it to `Music`.
- Click the diagnostic heading to select a reported Swift source line. Direct pattern literals glow while their compiled source events play. The attached timeline scrolls with the code; scroll over either pane.
- Use the lower-right layout button to put the rhythm view below the code.

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
| Other source settings, effects, buses | Explicit unsupported-feature diagnostic; current audio survives |

This first version prepares finite PCM loops offline. Loops are padded to whole bars, bounded to 32 beats and 16 seconds. Source, event and graph limits bound preparation work. Synth voices use short edge fades; sustained effect tails and arbitrary sample files are not implemented. The callback is synchronized and bounded, without a hard real-time latency guarantee. Line anchors come from the Swift compiler. Deleted anchors become unmapped until a new successful evaluation. Escaped, multiline, ambiguous or nonliteral pattern expressions are not assigned guessed text highlights. Only the individual token identified by the currently playing compiled event glows; repeated and shifted events preserve that token association. Source waves are pre-mix (before gain/pan/mute); the bottom stereo waveform and spectrum use the prepared master PCM at the transport cursor, not microphone or hardware loopback.

See [DESIGN.md](DESIGN.md) for ownership and failure contracts. This development app uses the adjacent SwiftMusic workspace for source provenance, which is not yet in the published 0.1.0 release. The app bundles both source packages so it can evaluate sessions when moved. No new library release is created by this change.

## Verification

On macOS 27.0 arm64 with Swift 6.4 snapshot 2026-08-14, 34 SwiftMusic tests and 14 editor-runtime tests passed. These cover compiler token provenance, transformed event timing, PCM peak data, literal ranges, Unicode edit anchors, FFT frequency/amplitude/stereo behavior and native AVAudioEngine playback while real Swift evaluations fail, time out, are cancelled, exceed diagnostic limits and recover. The initial combined app run exceeded its 120-second outer budget; the focused runtime integration passed in 49 seconds. Release builds pass with development-toolchain object verification warnings. This does not claim tested macOS 15 runtime behavior or hard real-time scheduling.
